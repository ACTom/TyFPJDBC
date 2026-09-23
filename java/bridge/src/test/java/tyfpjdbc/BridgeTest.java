package tyfpjdbc;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

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
}
