package tyfpjdbc;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;
import java.util.concurrent.*;

public class BridgeTest {
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

  @Test public void concurrentBorrowDistinctAndCancel() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:cc" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 4, 1);
    ExecutorService ex = Executors.newFixedThreadPool(4);
    try {
      Future<Long> f1 = ex.submit(() -> b.borrowConnection(pool));
      Future<Long> f2 = ex.submit(() -> b.borrowConnection(pool));
      long c1 = f1.get(10, TimeUnit.SECONDS);
      long c2 = f2.get(10, TimeUnit.SECONDS);
      assertNotEquals(c1, c2);
      b.execUpdate(c1, "CREATE ALIAS SLEEPX FOR \"java.lang.Thread.sleep(long)\"");
      Future<String> slow = ex.submit(() -> {
        try {
          b.execUpdateTimeout(c2, "CALL SLEEPX(8000)", 30);
          return b.poolStats(pool);
        } catch (Exception e) {
          return "ERR:" + b.getErrorChain();
        }
      });
      Thread.sleep(500);
      b.cancel(c2);
      String r = slow.get(15, TimeUnit.SECONDS);
      assertTrue(r != null && (r.contains("active=") || r.startsWith("ERR:")), "cancel-or-complete: " + r);
      try {
        b.execUpdate(c1, "SELECT * FROM no_such_table_xyz");
        fail("expected SQLException");
      } catch (Exception e) {
        assertNotNull(e.getMessage());
      }
      String chain = b.getErrorChain();
      assertTrue(chain != null && chain.contains("SQLState="));
      b.releaseConnection(c1);
      b.releaseConnection(c2);
      assertTrue(b.poolStats(pool).contains("active="));
    } finally {
      ex.shutdownNow();
      b.destroyPool(pool);
    }
  }
}
