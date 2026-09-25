package tyfpjdbc;

/** Throwaway smoke probe for Bridge (not a JUnit suite): version, pool,
 *  typed batch, window fetch, tx savepoint, metadata, cancel isolation,
 *  per-thread error chains. Exit nonzero on any failure. */
public class BridgeSmoke {
  static int fails = 0;
  static void ok(String n, boolean c) {
    System.out.println((c ? "PASS " : "FAIL ") + n);
    if (!c) fails++;
  }

  public static void main(String[] args) throws Exception {
    Bridge b = new Bridge();
    ok("version", "0.9.0".equals(b.getVersion()));

    PoolCfg h2 = new PoolCfg("jdbc:h2:mem:smoke;DB_CLOSE_DELAY=-1", "", "", "org.h2.Driver", 4, 1);
    long pool = b.createPool(h2);
    ok("pool", pool > 0);
    ok("pool-stats", b.poolActive(pool) >= 0 && b.poolIdle(pool) >= 0 && b.poolWaiting(pool) >= 0);

    long conn = b.borrowConn(pool);
    ok("borrow", conn > 0);
    ok("isvalid", b.isValid(conn, 2));
    ok("dbmeta", b.getDatabaseMeta(conn).startsWith("H2"));

    ok("ddl", b.execDirect(conn, "CREATE TABLE t(id BIGINT PRIMARY KEY, amt DECIMAL(10,2), name VARCHAR(50), ts TIMESTAMP)") == 0);

    long ins = b.prepare(conn, "INSERT INTO t VALUES(?,?,?,?)");
    b.bindLong(ins, 1, 1L);
    b.bindBigDecimal(ins, 2, "19.99");
    b.bindString(ins, 3, "hi");
    b.bindTimestamp(ins, 4, "2026-09-25 10:00:00");
    b.addBatch(ins);
    b.bindLong(ins, 1, 2L);
    b.bindBigDecimal(ins, 2, "3.50");
    b.bindString(ins, 3, "ho");
    b.bindTimestamp(ins, 4, "2026-09-25 11:00:00");
    b.addBatch(ins);
    ok("batch-2", b.execBatch(ins) == 2);
    String[] keys = b.getGeneratedKeys(ins);
    b.closeStmt(ins);

    long q = b.prepare(conn, "SELECT id,amt,name FROM t ORDER BY id");
    long cur = b.queryOpen(q, 100);
    ok("cols", b.cursorCols(cur) == 3);
    String[][] w1 = b.fetchWindow(cur, 1);
    ok("window-1", w1.length == 1 && "1".equals(w1[0][0]) && "19.99".equals(w1[0][1]));
    String[][] w2 = b.fetchWindow(cur, 10);
    ok("window-2", w2.length == 1 && "2".equals(w2[0][0]));
    b.closeCursor(cur);
    b.closeStmt(q);

    b.setAutoCommit(conn, false);
    long ins2 = b.prepare(conn, "INSERT INTO t VALUES(?,?,?,?)");
    b.bindLong(ins2, 1, 3L);
    b.bindBigDecimal(ins2, 2, "1.00");
    b.bindString(ins2, 3, "tmp");
    b.bindTimestamp(ins2, 4, "2026-09-25 12:00:00");
    b.execUpdate(ins2);
    b.savepoint(conn, "sp1");
    b.bindLong(ins2, 1, 4L);
    b.bindBigDecimal(ins2, 2, "2.00");
    b.bindString(ins2, 3, "tmp2");
    b.bindTimestamp(ins2, 4, "2026-09-25 13:00:00");
    b.execUpdate(ins2);
    b.rollbackTo(conn, "sp1");
    b.releaseSavepoint(conn, "sp1");
    b.commit(conn);
    b.closeStmt(ins2);
    long cnt = b.prepare(conn, "SELECT COUNT(*) FROM t");
    long cc = b.queryOpen(cnt, 10);
    String[][] cw = b.fetchWindow(cc, 10);
    b.closeCursor(cc);
    b.closeStmt(cnt);
    ok("savepoint-rollback", cw.length == 1 && "3".equals(cw[0][0]));
    b.setAutoCommit(conn, true);

    String[][] tabs = b.getTables(conn, "T");
    ok("meta-tables", tabs.length >= 1);
    String[] pks = b.getPrimaryKeys(conn, "T");
    ok("meta-pk", pks.length == 1 && "ID".equalsIgnoreCase(pks[0]));

    // cancel isolation: cancelling s2 must not break s1.
    // H2 SELECTs execute eagerly so cancel is a no-op success; assert only
    // that the OTHER statement still runs, which is the isolation property.
    long s1 = b.prepare(conn, "SELECT 1");
    long s2 = b.prepare(conn, "SELECT 2");
    b.cancel(s2);
    boolean s1ok = true;
    String s1err = "";
    try {
      long cq = b.queryOpen(s1, 10);
      String[][] sw = b.fetchWindow(cq, 10);
      s1ok = sw.length == 1 && "1".equals(sw[0][0]);
      b.closeCursor(cq);
    } catch (Exception e) { s1ok = false; s1err = String.valueOf(e.getMessage()); }
    ok("cancel-isolation", s1ok);
    if (!s1ok) System.out.println("CANCEL-DBG " + s1err + " chain=" + b.getErrorChain());
    b.closeStmt(s1);
    b.closeStmt(s2);

    // error chain is per-thread
    try { b.borrowConn(0); } catch (Exception ignored) {}
    final String[] other = new String[1];
    Thread t = new Thread(() -> { other[0] = b.getErrorChain(); });
    t.start(); t.join();
    ok("error-thread-local", b.getErrorChain().contains("no pool") && (other[0] == null || other[0].isEmpty()));

    boolean badSp = false;
    try { b.savepoint(conn, "evil name!"); } catch (Exception e) { badSp = true; }
    ok("savepoint-whitelist", badSp);

    b.closeConn(conn);
    b.destroyPool(pool);
    System.out.println("TOTAL fails=" + fails);
    if (fails > 0) System.exit(1);
  }
}
