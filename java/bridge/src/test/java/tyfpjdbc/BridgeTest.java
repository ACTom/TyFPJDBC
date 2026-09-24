package tyfpjdbc;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import java.util.concurrent.*;

public class BridgeTest {
  static final String LONG_COUNT =
    "SELECT COUNT(*) FROM SYSTEM_RANGE(1,200000) A, SYSTEM_RANGE(1,200) B";
  static final String LONG_CTAS =
    "CREATE TABLE big_%s AS SELECT A.X AS a, B.X AS b FROM SYSTEM_RANGE(1,300000) A, SYSTEM_RANGE(1,300) B";

  @Test public void versionMatchesSpec() {
    assertEquals("1.0.0", new Bridge().getVersion());
  }

  @Test public void h2RoundTrip() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:t" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    b.execUpdate(c, "CREATE TABLE t(id INT PRIMARY KEY, name VARCHAR(100))");
    b.execUpdate(c, "INSERT INTO t VALUES(1,'hello')");
    b.execUpdate(c, "INSERT INTO t VALUES(2,'中文测试')");
    String[][] rows = b.fetchBatch(c, "SELECT id,name FROM t ORDER BY id", 0, 10, 100);
    assertEquals(2, rows.length);
    assertEquals("hello", rows[0][1]);
    assertEquals("中文测试", rows[1][1]);
    assertTrue(b.poolStats(pool).contains("active="));
    b.releaseConnection(c);
    b.destroyPool(pool);
  }

  @Test public void sqliteRoundTrip() throws Exception {
    Bridge b = new Bridge();
    String db = System.getProperty("java.io.tmpdir") + "/tyfpjdbc-sqlite-" + System.nanoTime() + ".db";
    long pool = b.createPool("jdbc:sqlite:" + db, "", "", 2, 1);
    try {
      long c = b.borrowConnection(pool);
      try {
        String[][] one = b.fetchBatch(c, "SELECT 1", 0, 10, 100);
        assertEquals(1, one.length);
        assertEquals("1", one[0][0]);
        b.execUpdate(c, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)");
        b.execUpdate(c, "INSERT INTO t VALUES(1,'hello')");
        b.execUpdate(c, "INSERT INTO t VALUES(2,'中文测试')");
        String[][] rows = b.fetchBatch(c, "SELECT id,name FROM t ORDER BY id", 0, 10, 100);
        assertEquals(2, rows.length);
        assertEquals("hello", rows[0][1]);
        assertEquals("中文测试", rows[1][1]);
        assertTrue(b.poolStats(pool).contains("active="));
        b.releaseConnection(c);
      } finally {
        b.destroyPool(pool);
        new java.io.File(db).delete();
      }
    } catch (Exception e) {
      try { b.destroyPool(pool); } catch (Exception ignored) {}
      new java.io.File(db).delete();
      throw e;
    }
  }

  @Test public void batchedFetchPagesLargeResult() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:pg" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    b.execUpdate(c, "CREATE TABLE big(id INT PRIMARY KEY, name VARCHAR(100))");
    for (int i = 1; i <= 2500; i++) {
      b.execUpdate(c, "INSERT INTO big VALUES(" + i + ",'row-" + i + "')");
    }
    int off = 0, total = 0, maxPage = 0, pages = 0, nonEmpty = 0;
    while (true) {
      String[][] page = b.fetchBatch(c, "SELECT id,name FROM big ORDER BY id", off, 1000, 1000);
      if (page.length > maxPage) maxPage = page.length;
      total += page.length;
      off += page.length;
      pages++;
      if (page.length == 0) break;
      nonEmpty++;
      assertEquals(String.valueOf(off - page.length + 1), page[0][0]);
    }
    assertEquals(2500, total);
    assertTrue(maxPage <= 1000, "pages must be bounded, max=" + maxPage);
    assertEquals(3, nonEmpty);
    assertEquals(4, pages);
    b.releaseConnection(c);
    b.destroyPool(pool);
  }

  @Test public void concurrentBorrowDistinct() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:cc" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 4, 1);
    ExecutorService ex = Executors.newFixedThreadPool(4);
    try {
      Future<Long> f1 = ex.submit(() -> b.borrowConnection(pool));
      Future<Long> f2 = ex.submit(() -> b.borrowConnection(pool));
      long c1 = f1.get(10, TimeUnit.SECONDS);
      long c2 = f2.get(10, TimeUnit.SECONDS);
      assertNotEquals(c1, c2);
      b.releaseConnection(c1);
      b.releaseConnection(c2);
      assertTrue(b.poolStats(pool).contains("active="));
    } finally {
      ex.shutdownNow();
      b.destroyPool(pool);
    }
  }

  @Test public void cancelInterruptsLongQuery() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:cx" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 4, 1);
    ExecutorService ex = Executors.newSingleThreadExecutor();
    long c = b.borrowConnection(pool);
    try {
      Future<String> slow = ex.submit(() -> {
        long t0 = System.currentTimeMillis();
        try {
          b.fetchBatch(c, LONG_COUNT, 0, 5, 100);
          return "COMPLETED-ELAPSED=" + (System.currentTimeMillis() - t0);
        } catch (Exception e) {
          return "THREW-ELAPSED=" + (System.currentTimeMillis() - t0);
        }
      });
      Thread.sleep(500);
      b.cancel(c);
      Thread.sleep(1000);
      b.cancel(c);
      String r = slow.get(120, TimeUnit.SECONDS);
      assertTrue(r.startsWith("THREW-"), "cancel must abort the query, got: " + r);
      long elapsed = Long.parseLong(r.substring("THREW-ELAPSED=".length()));
      assertTrue(elapsed < 30000, "abort must be fast, elapsed=" + elapsed);
      String chain = b.getErrorChain();
      assertTrue(chain != null && chain.contains("57014"), "chain must carry cancel state, got: " + chain);
      b.releaseConnection(c);
    } finally {
      ex.shutdownNow();
      b.destroyPool(pool);
    }
  }

  @Test public void queryTimeoutAbortsLongUpdate() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:to" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      String sql = String.format(LONG_CTAS, "t" + System.nanoTime());
      long t0 = System.currentTimeMillis();
      boolean threw = false;
      try {
        b.execUpdateTimeout(c, sql, 1);
      } catch (Exception e) {
        threw = true;
      }
      long elapsed = System.currentTimeMillis() - t0;
      assertTrue(threw, "1s timeout must abort the 90M-row CTAS");
      assertTrue(elapsed < 30000, "timeout abort must be fast, elapsed=" + elapsed);
      String chain = b.getErrorChain();
      assertTrue(chain != null && chain.contains("57014"), "chain must carry timeout state, got: " + chain);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }
}
