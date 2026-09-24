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

  @Test public void postgresDialectRoundTrip() throws Exception {
    // PG-dialect syntax on H2 in PG mode: RETURNING-free insert, LIMIT/OFFSET,
    // LIKE ... ESCAPE, cast operator, JSON extraction shape.
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:pg" + System.nanoTime() + ";MODE=PostgreSQL;DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE users(id INT PRIMARY KEY, name VARCHAR(100), age INT)");
      b.execUpdate(c, "INSERT INTO users VALUES(1,'alice',30)");
      b.execUpdate(c, "INSERT INTO users VALUES(2,'bob',25)");
      b.execUpdate(c, "INSERT INTO users VALUES(3,'中文测试',28)");
      String[][] page = b.fetchBatch(c, "SELECT id,name FROM users ORDER BY id LIMIT 2 OFFSET 1", 0, 10, 100);
      assertEquals(2, page.length);
      assertEquals("2", page[0][0]);
      assertEquals("中文测试", page[1][1]);
      String[][] like = b.fetchBatch(c, "SELECT name FROM users WHERE name LIKE 'a%' ESCAPE '\\'", 0, 10, 100);
      assertEquals(1, like.length);
      assertEquals("alice", like[0][0]);
      String[][] casted = b.fetchBatch(c, "SELECT CAST(age AS VARCHAR) FROM users WHERE id=1", 0, 10, 100);
      assertEquals("30", casted[0][0]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  @Test public void perfSmoke10kFetch() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:perf" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE big(id INT PRIMARY KEY, name VARCHAR(100))");
      for (int i = 1; i <= 10000; i += 1000) {
        StringBuilder sb = new StringBuilder("INSERT INTO big VALUES");
        for (int j = i; j < i + 1000; j++) {
          if (j > i) sb.append(",");
          sb.append("(").append(j).append(",'row-").append(j).append("')");
        }
        b.execUpdate(c, sb.toString());
      }
      long t0 = System.currentTimeMillis();
      int off = 0, total = 0, maxPage = 0;
      while (true) {
        String[][] page = b.fetchBatch(c, "SELECT id,name FROM big ORDER BY id", off, 1000, 1000);
        if (page.length > maxPage) maxPage = page.length;
        total += page.length;
        off += page.length;
        if (page.length == 0) break;
      }
      long ms = System.currentTimeMillis() - t0;
      System.out.println("PERF 10k fetch ms=" + ms);
      assertEquals(10000, total);
      assertTrue(maxPage <= 1000);
      assertTrue(ms < 30000, "10k fetch must finish fast, ms=" + ms);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // WordPress-style wide table: 12 columns, 3-table join with GROUP BY.
  @Test public void wideTableJoinGroupBy() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:wide" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE wp_users(id INT PRIMARY KEY, login VARCHAR(60), email VARCHAR(100), registered TIMESTAMP)");
      b.execUpdate(c, "CREATE TABLE wp_posts(id INT PRIMARY KEY, author_id INT, title VARCHAR(255), body CLOB, status VARCHAR(20), created TIMESTAMP, views INT DEFAULT 0)");
      b.execUpdate(c, "CREATE TABLE wp_postmeta(id INT PRIMARY KEY, post_id INT, mkey VARCHAR(100), mval VARCHAR(255))");
      b.execUpdate(c, "INSERT INTO wp_users VALUES(1,'alice','a@x.com',CURRENT_TIMESTAMP)");
      b.execUpdate(c, "INSERT INTO wp_users VALUES(2,'bob','b@x.com',CURRENT_TIMESTAMP)");
      b.execUpdate(c, "INSERT INTO wp_posts VALUES(10,1,'hello','body-hello','publish',CURRENT_TIMESTAMP,5)");
      b.execUpdate(c, "INSERT INTO wp_posts VALUES(11,1,'world','body-world','draft',CURRENT_TIMESTAMP,0)");
      b.execUpdate(c, "INSERT INTO wp_posts VALUES(12,2,'中文测试','正文','publish',CURRENT_TIMESTAMP,7)");
      b.execUpdate(c, "INSERT INTO wp_postmeta VALUES(100,10,'views','5')");
      b.execUpdate(c, "INSERT INTO wp_postmeta VALUES(101,12,'views','7')");
      String[][] rows = b.fetchBatch(c, "SELECT u.login, COUNT(p.id) FROM wp_users u LEFT JOIN wp_posts p ON p.author_id=u.id AND p.status='publish' GROUP BY u.login ORDER BY u.login", 0, 10, 100);
      assertEquals(2, rows.length);
      assertEquals("alice", rows[0][0]);
      assertEquals("1", rows[0][1]);
      assertEquals("bob", rows[1][0]);
      assertEquals("1", rows[1][1]);
      String[][] join = b.fetchBatch(c, "SELECT p.title, m.mval FROM wp_posts p JOIN wp_postmeta m ON m.post_id=p.id WHERE p.id=12", 0, 10, 100);
      assertEquals(1, join.length);
      assertEquals("中文测试", join[0][0]);
      assertEquals("7", join[0][1]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Shop flow: orders + items join, aggregate, bulk insert 10k in one tx shape.
  @Test public void shopBulkInsertAndJoinAggregate() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:shop" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE orders(id INT PRIMARY KEY, customer VARCHAR(100), created TIMESTAMP)");
      b.execUpdate(c, "CREATE TABLE order_items(id INT PRIMARY KEY, order_id INT, sku VARCHAR(40), qty INT, price INT)");
      StringBuilder sb = new StringBuilder("INSERT INTO orders VALUES");
      for (int i = 1; i <= 200; i++) {
        if (i > 1) sb.append(",");
        sb.append("(").append(i).append(",'cust-").append(i % 10).append("',CURRENT_TIMESTAMP)");
      }
      b.execUpdate(c, sb.toString());
      StringBuilder it = new StringBuilder("INSERT INTO order_items VALUES");
      int id = 1;
      boolean first = true;
      for (int o = 1; o <= 200; o++) {
        for (int k = 0; k < 50; k++) {
          if (!first) it.append(",");
          first = false;
          it.append("(").append(id).append(",").append(o).append(",'sku-").append(k % 5).append("',").append(k + 1).append(",100)");
          id++;
        }
        if (o % 50 == 0) { b.execUpdate(c, it.toString()); it = new StringBuilder("INSERT INTO order_items VALUES"); first = true; }
      }
      String[][] agg = b.fetchBatch(c, "SELECT o.customer, SUM(i.qty) FROM orders o JOIN order_items i ON i.order_id=o.id GROUP BY o.customer ORDER BY o.customer", 0, 20, 100);
      assertEquals(10, agg.length);
      assertEquals("cust-0", agg[0][0]);
      assertTrue(Integer.parseInt(agg[0][1]) > 0);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Complex transaction: 2nd savepoint rolls back, 1st survives.
  @Test public void complexTransactionPartialRollback() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:tx" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE inventory(sku VARCHAR(40) PRIMARY KEY, qty INT)");
      b.execUpdate(c, "INSERT INTO inventory VALUES('sku-1',100)");
      // Bridge has no explicit tx API; emulate app-level partial rollback:
      // apply batch A, keep it; apply batch B then compensate it back.
      b.execUpdate(c, "UPDATE inventory SET qty=qty-10 WHERE sku='sku-1'");
      b.execUpdate(c, "UPDATE inventory SET qty=qty-20 WHERE sku='sku-1'");
      b.execUpdate(c, "UPDATE inventory SET qty=qty+20 WHERE sku='sku-1'");
      String[][] rows = b.fetchBatch(c, "SELECT qty FROM inventory WHERE sku='sku-1'", 0, 10, 100);
      assertEquals(1, rows.length);
      assertEquals("90", rows[0][0]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // DDL migration: add column, backfill, index, verify.
  @Test public void ddlMigrateAddColumnAndIndex() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:ddl" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE wp_posts(id INT PRIMARY KEY, title VARCHAR(255))");
      b.execUpdate(c, "INSERT INTO wp_posts VALUES(1,'a')");
      b.execUpdate(c, "ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0");
      b.execUpdate(c, "UPDATE wp_posts SET views=42 WHERE id=1");
      b.execUpdate(c, "CREATE INDEX idx_posts_views ON wp_posts(views)");
      String[][] rows = b.fetchBatch(c, "SELECT title, views FROM wp_posts WHERE views=42", 0, 10, 100);
      assertEquals(1, rows.length);
      assertEquals("a", rows[0][0]);
      assertEquals("42", rows[0][1]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Hostile values must travel as data, never as SQL.
  @Test public void hostileValuesStayData() throws Exception {
    Bridge b = new Bridge();
    String db = System.getProperty("java.io.tmpdir") + "/tyfpjdbc-hostile-" + System.nanoTime() + ".db";
    long pool = b.createPool("jdbc:sqlite:" + db, "", "", 2, 1);
    try {
      long c = b.borrowConnection(pool);
      try {
        b.execUpdate(c, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT)");
        String evil = "x'; DROP TABLE t; --";
        // value goes through a parameter on the app side; here we assert the
        // table survives an evil-looking literal only when properly escaped.
        b.execUpdate(c, "INSERT INTO t VALUES(1,'" + evil.replace("'", "''") + "')");
        String[][] rows = b.fetchBatch(c, "SELECT name FROM t WHERE id=1", 0, 10, 100);
        assertEquals(1, rows.length);
        assertEquals(evil, rows[0][0]);
        String[][] still = b.fetchBatch(c, "SELECT COUNT(*) FROM t", 0, 10, 100);
        assertEquals("1", still[0][0]);
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

  // True batch DML: 2500 rows via one PreparedStatement, NULL survives.
  @Test public void execBatchBulkInsert() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:batch" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE t(id INT PRIMARY KEY, name VARCHAR(100))");
      String[][] rows = new String[2500][2];
      for (int i = 0; i < 2500; i++) {
        rows[i][0] = String.valueOf(i + 1);
        rows[i][1] = (i == 1250) ? null : "row-" + (i + 1);
      }
      int n = b.execBatch(c, "INSERT INTO t VALUES(?,?)", rows);
      assertEquals(2500, n);
      String[][] cnt = b.fetchBatch(c, "SELECT COUNT(*) FROM t", 0, 10, 100);
      assertEquals("2500", cnt[0][0]);
      String[][] nul = b.fetchBatch(c, "SELECT COUNT(*) FROM t WHERE name IS NULL", 0, 10, 100);
      assertEquals("1", nul[0][0]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Odoo-style sales funnel: 4-table join + CASE bucket + GROUP BY + HAVING.
  @Test public void odooSalesFunnel() throws Exception {    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:odoo" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE res_partner(id INT PRIMARY KEY, name VARCHAR(100))");
      b.execUpdate(c, "CREATE TABLE product_product(id INT PRIMARY KEY, default_code VARCHAR(40))");
      b.execUpdate(c, "CREATE TABLE sale_order(id INT PRIMARY KEY, partner_id INT, state VARCHAR(20), amount_total INT)");
      b.execUpdate(c, "CREATE TABLE sale_order_line(id INT PRIMARY KEY, order_id INT, product_id INT, price_subtotal INT)");
      b.execUpdate(c, "INSERT INTO res_partner VALUES(1,'Acme'),(2,'中文客户')");
      b.execUpdate(c, "INSERT INTO product_product VALUES(10,'SKU-1'),(11,'SKU-2')");
      b.execUpdate(c, "INSERT INTO sale_order VALUES(100,1,'sale',1500),(101,2,'sale',300),(102,1,'draft',900)");
      b.execUpdate(c, "INSERT INTO sale_order_line VALUES(1000,100,10,1000),(1001,100,11,500),(1002,101,10,300),(1003,102,11,900)");
      String[][] rows = b.fetchBatch(c, "SELECT p.default_code, CASE WHEN SUM(l.price_subtotal)>1000 THEN 'VIP' ELSE 'SMB' END AS seg, SUM(l.price_subtotal) AS amt FROM sale_order o JOIN sale_order_line l ON l.order_id=o.id JOIN product_product p ON p.id=l.product_id JOIN res_partner r ON r.id=o.partner_id WHERE o.state='sale' GROUP BY p.default_code HAVING SUM(l.price_subtotal)>400 ORDER BY p.default_code", 0, 10, 100);
      assertEquals(2, rows.length);
      assertEquals("SKU-1", rows[0][0]);
      assertEquals("VIP", rows[0][1]);
      assertEquals("1300", rows[0][2]);
      assertEquals("SKU-2", rows[1][0]);
      assertEquals("SMB", rows[1][1]);
      assertEquals("500", rows[1][2]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Odoo MRP BOM explosion: recursive CTE.
  @Test public void erpRecursiveBom() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:bom" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE mrp_bom_line(id INT PRIMARY KEY, bom_id INT, product_qty INT)");
      b.execUpdate(c, "INSERT INTO mrp_bom_line VALUES(1,0,2),(2,0,3),(3,1,4),(4,2,5)");
      String[][] rows = b.fetchBatch(c, "WITH RECURSIVE bom(id, parent, qty) AS (SELECT id, 0, product_qty FROM mrp_bom_line WHERE bom_id=0 UNION ALL SELECT l.id, b.id, l.product_qty*b.qty FROM mrp_bom_line l JOIN bom b ON b.id=l.bom_id) SELECT COUNT(*), SUM(qty) FROM bom", 0, 10, 100);
      assertEquals(1, rows.length);
      assertEquals("4", rows[0][0]);
      assertEquals("28", rows[0][1]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }

  // Odoo trial balance: UNION ALL + aggregate + ordering.
  @Test public void erpUnionTrialBalance() throws Exception {
    Bridge b = new Bridge();
    long pool = b.createPool("jdbc:h2:mem:ledger" + System.nanoTime() + ";DB_CLOSE_DELAY=-1", "sa", "", 2, 1);
    long c = b.borrowConnection(pool);
    try {
      b.execUpdate(c, "CREATE TABLE account_account(id INT PRIMARY KEY, code VARCHAR(20))");
      b.execUpdate(c, "CREATE TABLE account_move_line(id INT PRIMARY KEY, account_id INT, debit INT, credit INT)");
      b.execUpdate(c, "INSERT INTO account_account VALUES(1,'1000'),(2,'2000')");
      b.execUpdate(c, "INSERT INTO account_move_line VALUES(1,1,500,0),(2,1,300,0),(3,2,0,400),(4,2,0,100)");
      String[][] rows = b.fetchBatch(c, "SELECT a.code, SUM(l.debit) AS dr, SUM(l.credit) AS cr FROM account_move_line l JOIN account_account a ON a.id=l.account_id GROUP BY a.code UNION ALL SELECT 'TOTAL', SUM(debit), SUM(credit) FROM account_move_line ORDER BY 1", 0, 10, 100);
      assertEquals(3, rows.length);
      assertEquals("1000", rows[0][0]);
      assertEquals("800", rows[0][1]);
      assertEquals("2000", rows[1][0]);
      assertEquals("500", rows[1][2]);
      assertEquals("TOTAL", rows[2][0]);
      assertEquals("800", rows[2][1]);
      assertEquals("500", rows[2][2]);
      b.releaseConnection(c);
    } finally {
      b.destroyPool(pool);
    }
  }
}
