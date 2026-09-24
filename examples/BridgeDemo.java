package tyfpjdbc;

/** BridgeDemo: the Java-side counterpart of examples/ex01.
 *  createPool -> borrow -> execUpdate/fetchBatch -> poolStats ->
 *  release -> destroy. Run against in-memory H2, no install needed.
 *  Usage: java -cp <jars> tyfpjdbc.BridgeDemo
 */
public class BridgeDemo {
  public static void main(String[] args) throws Exception {
    Bridge b = new Bridge();
    System.out.println("bridge=" + b.getVersion());
    long pool = b.createPool("jdbc:h2:mem:demo" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE t(id INT PRIMARY KEY, name VARCHAR(100))");
      b.execUpdate(c, "INSERT INTO t VALUES(1,'hello')");
      b.execUpdate(c, "INSERT INTO t VALUES(2,'中文测试')");
      String[][] rows = b.fetchBatch(c, "SELECT id,name FROM t ORDER BY id", 0, 10, 100);
      for (String[] r : rows) System.out.println("row " + r[0] + " => " + r[1]);
      System.out.println(b.poolStats(pool));
      System.out.println("errorChain=" + b.getErrorChain());
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
    System.out.println("demo ok");
  }
}
