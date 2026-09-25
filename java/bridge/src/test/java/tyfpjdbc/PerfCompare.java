package tyfpjdbc;

/** Perf harness: TyFPJDBC Bridge + sqlite-jdbc against a file DB.
 *  Same workload as FPC TestPerfCompare (sqlite3conn direct):
 *  bulk insert / full scan / paged fetch / bulk update.
 *  Pool creation + warmup happen BEFORE the timers, so JVM/Hikari
 *  startup is never counted. Prints PERF lines parsed by run-matrix.ps1.
 *  Usage: java -cp ... tyfpjdbc.PerfCompare <dbPath> <rows>
 */
public class PerfCompare {
  static String[][] fetchAll(Bridge b, long c, String sql, int size) throws Exception {
    java.util.List<String[]> out = new java.util.ArrayList<>();
    long s = b.prepare(c, sql);
    try {
      long cur = b.queryOpen(s, size);
      try {
        while (true) {
          String[][] w = b.fetchWindow(cur, size);
          if (w.length == 0) break;
          for (String[] r : w) out.add(r);
        }
      } finally {
        b.closeCursor(cur);
      }
    } finally {
      b.closeStmt(s);
    }
    return out.toArray(new String[0][]);
  }

  public static void main(String[] args) throws Exception {
    String db = args.length > 0 ? args[0] : "perf-bridge.db";
    int rows = args.length > 1 ? Integer.parseInt(args[1]) : 20000;
    new java.io.File(db).delete();

    Bridge b = new Bridge();
    long pool = b.createPool(new PoolCfg("jdbc:sqlite:" + db, "", "", "org.sqlite.JDBC", 4, 1));
    long c = b.borrowConn(pool);
    try {
      // warmup (not timed)
      b.execDirect(c, "CREATE TABLE bench(id INTEGER PRIMARY KEY, name TEXT, payload TEXT, qty INT)");
      long w = b.prepare(c, "INSERT INTO bench VALUES(?,?,?,?)");
      for (int i = 1; i <= 100; i++) {
        b.bindLong(w, 1, i);
        b.bindString(w, 2, "row-" + i);
        b.bindString(w, 3, "payload-中文-" + i);
        b.bindLong(w, 4, i % 100);
        b.addBatch(w);
      }
      b.execBatch(w);
      b.closeStmt(w);
      fetchAll(b, c, "SELECT COUNT(*) FROM bench", 10);
      b.execDirect(c, "DELETE FROM bench");

      // phase 1: bulk insert, chunked prepares; each execBatch call is one
      // transaction, so chunk count = commit count.
      long t0 = System.currentTimeMillis();
      w = b.prepare(c, "INSERT INTO bench VALUES(?,?,?,?)");
      try {
        for (int j = 1; j <= rows; j++) {
          b.bindLong(w, 1, j);
          b.bindString(w, 2, "row-" + j);
          b.bindString(w, 3, "payload-中文-" + j);
          b.bindLong(w, 4, j % 100);
          b.addBatch(w);
          if (j % 1000 == 0) {
            int n = b.execBatch(w);
            if (n != 1000) throw new RuntimeException("batch-count want 1000 got " + n);
          }
        }
      } finally {
        b.closeStmt(w);
      }
      long msIns = System.currentTimeMillis() - t0;
      System.out.println("PERF bridge-insert ms=" + msIns + " rows=" + rows + " rows_per_sec=" + (rows * 1000L / (msIns + 1)));

      // phase 2: full scan, windowed fetch
      t0 = System.currentTimeMillis();
      int cnt = 0;
      long sumTouch = 0;
      {
        long s = b.prepare(c, "SELECT id, name, payload, qty FROM bench ORDER BY id");
        try {
          long cur = b.queryOpen(s, 1000);
          try {
            while (true) {
              String[][] page = b.fetchWindow(cur, 1000);
              if (page.length == 0) break;
              for (String[] r : page) {
                cnt++;
                sumTouch += Long.parseLong(r[3]) + r[1].length() * 0;
              }
            }
          } finally {
            b.closeCursor(cur);
          }
        } finally {
          b.closeStmt(s);
        }
      }
      long msScan = System.currentTimeMillis() - t0;
      if (cnt != rows) throw new RuntimeException("scan-count want " + rows + " got " + cnt);
      System.out.println("PERF bridge-scan ms=" + msScan + " rows=" + cnt + " rows_per_sec=" + (cnt * 1000L / (msScan + 1)));

      // phase 3: paged fetch, 2 cols, SQL-level paging.
      t0 = System.currentTimeMillis();
      int off = 0; cnt = 0; int pages = 0;
      while (off < rows) {
        String[][] page = fetchAll(b, c, "SELECT id, name FROM bench ORDER BY id LIMIT 1000 OFFSET " + off, 1000);
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
      b.execDirect(c, "UPDATE bench SET qty=qty+1 WHERE id%2=0");
      long msUpd = System.currentTimeMillis() - t0;
      String[][] s = fetchAll(b, c, "SELECT SUM(qty) FROM bench", 10);
      long checksum = Long.parseLong(s[0][0]);
      long want = ((long) (rows / 100) * 4950) + (rows / 2);
      if (checksum != want) throw new RuntimeException("checksum want " + want + " got " + checksum);
      System.out.println("PERF bridge-update ms=" + msUpd + " checksum=" + checksum);

      b.closeConn(c);
      System.out.println("PERF-DONE rows=" + rows);
    } finally {
      b.destroyPool(pool);
    }
  }
}
