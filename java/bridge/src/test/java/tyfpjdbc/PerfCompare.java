package tyfpjdbc;

/** Perf harness: TyFPJDBC Bridge + sqlite-jdbc against a file DB.
 *  Same workload as FPC TestPerfCompare (sqlite3conn direct):
 *  bulk insert / full scan / paged fetch / bulk update.
 *  Pool creation + warmup happen BEFORE the timers, so JVM/Hikari
 *  startup is never counted. Prints PERF lines parsed by run-matrix.ps1.
 *  Usage: java -cp ... tyfpjdbc.PerfCompare <dbPath> <rows>
 */
public class PerfCompare {
  public static void main(String[] args) throws Exception {
    String db = args.length > 0 ? args[0] : "perf-bridge.db";
    int rows = args.length > 1 ? Integer.parseInt(args[1]) : 20000;
    new java.io.File(db).delete();

    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:sqlite:" + db, "", "", 4, 1);
    long c = b.borrowConnection(pool);
    try {
      // warmup (not timed)
      b.execUpdate(c, "CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT, payload TEXT, qty INT)");
      for (int i = 1; i <= 100; i++) {
        b.execUpdate(c, "INSERT INTO bench VALUES(" + i + ",'row-" + i + "','payload-中文-" + i + "'," + (i % 100) + ")");
      }
      b.fetchBatch(c, "SELECT COUNT(*) FROM bench", 0, 10, 100);
      b.execUpdate(c, "DELETE FROM bench");

      // phase 1: bulk insert, 500-row multi-value batches
      long t0 = System.currentTimeMillis();
      for (int i = 1; i <= rows; i += 500) {
        StringBuilder sb = new StringBuilder("INSERT INTO bench VALUES");
        int last = Math.min(i + 499, rows);
        for (int j = i; j <= last; j++) {
          if (j > i) sb.append(",");
          sb.append("(").append(j).append(",'row-").append(j).append("','payload-中文-").append(j).append("',").append(j % 100).append(")");
        }
        b.execUpdate(c, sb.toString());
      }
      long msIns = System.currentTimeMillis() - t0;
      System.out.println("PERF bridge-insert ms=" + msIns + " rows=" + rows + " rows_per_sec=" + (rows * 1000L / (msIns + 1)));

      // phase 2: full scan in 1000-row pages, touch every field
      t0 = System.currentTimeMillis();
      int off = 0, cnt = 0;
      long sum = 0;
      while (true) {
        String[][] page = b.fetchBatch(c, "SELECT id, name, payload, qty FROM bench ORDER BY id", off, 1000, 1000);
        if (page.length == 0) break;
        for (String[] r : page) {
          cnt++;
          sum += Long.parseLong(r[3]) + r[1].length() * 0;
        }
        off += page.length;
      }
      long msScan = System.currentTimeMillis() - t0;
      if (cnt != rows) throw new RuntimeException("scan-count want " + rows + " got " + cnt);
      System.out.println("PERF bridge-scan ms=" + msScan + " rows=" + cnt + " rows_per_sec=" + (cnt * 1000L / (msScan + 1)));

      // phase 3: paged fetch, 2 cols
      t0 = System.currentTimeMillis();
      off = 0; cnt = 0; int pages = 0;
      while (off < rows) {
        String[][] page = b.fetchBatch(c, "SELECT id, name FROM bench ORDER BY id", off, 1000, 1000);
        if (page.length == 0) break;
        cnt += page.length;
        off += page.length;
        pages++;
      }
      long msPage = System.currentTimeMillis() - t0;
      if (cnt != rows) throw new RuntimeException("paged-count want " + rows + " got " + cnt);
      System.out.println("PERF bridge-paged ms=" + msPage + " rows=" + cnt + " pages=" + pages + " rows_per_sec=" + (cnt * 1000L / (msPage + 1)));

      // phase 4: bulk update half the rows
      t0 = System.currentTimeMillis();
      b.execUpdate(c, "UPDATE bench SET qty=qty+1 WHERE id%2=0");
      long msUpd = System.currentTimeMillis() - t0;
      String[][] s = b.fetchBatch(c, "SELECT SUM(qty) FROM bench", 0, 10, 100);
      long checksum = Long.parseLong(s[0][0]);
      long want = ((long) (rows / 100) * 4950) + (rows / 2);
      if (checksum != want) throw new RuntimeException("checksum want " + want + " got " + checksum);
      System.out.println("PERF bridge-update ms=" + msUpd + " checksum=" + checksum);

      b.releaseConnection(c);
      System.out.println("PERF-DONE rows=" + rows);
    } finally {
      b.destroyPool(pool);
    }
  }
}
