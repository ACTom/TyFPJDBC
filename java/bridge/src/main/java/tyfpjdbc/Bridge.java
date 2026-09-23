package tyfpjdbc;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.sql.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

public class Bridge {
  public static final String VERSION = "1.0.0";
  private final AtomicLong ids = new AtomicLong(0);
  private final Map<Long, HikariDataSource> pools = new ConcurrentHashMap<>();
  private final Map<Long, Connection> conns = new ConcurrentHashMap<>();
  private final Map<Long, Statement> stmts = new ConcurrentHashMap<>();
  private volatile String lastError = "";

  public String getVersion() { return VERSION; }

  public long createPool(String jdbcUrl, String user, String pw, int maxPool, int minIdle) {
    HikariConfig c = new HikariConfig();
    c.setJdbcUrl(jdbcUrl);
    c.setUsername(user);
    c.setPassword(pw);
    c.setMaximumPoolSize(maxPool);
    c.setMinimumIdle(minIdle);
    long id = ids.incrementAndGet();
    pools.put(id, new HikariDataSource(c));
    return id;
  }

  public void destroyPool(long poolId) {
    HikariDataSource ds = pools.remove(poolId);
    if (ds != null) ds.close();
  }

  public long borrowConnection(long poolId) throws SQLException {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) throw new SQLException("no pool", "08000", 31);
    try {
      Connection c = ds.getConnection();
      long id = ids.incrementAndGet();
      conns.put(id, c);
      return id;
    } catch (SQLException e) {
      recordChain(e);
      throw e;
    }
  }

  public void releaseConnection(long connId) throws SQLException {
    Connection c = conns.remove(connId);
    if (c != null) c.close();
  }

  public int execUpdate(long connId, String sql) throws SQLException {
    return execUpdateTimeout(connId, sql, 0);
  }

  public int execUpdateTimeout(long connId, String sql, int timeoutSecs) throws SQLException {
    Connection c = conns.get(connId);
    if (c == null) throw new SQLException("no conn", "08000", 32);
    try (Statement s = c.createStatement()) {
      if (timeoutSecs > 0) s.setQueryTimeout(timeoutSecs);
      stmts.put(connId, s);
      try {
        return s.executeUpdate(sql);
      } finally {
        stmts.remove(connId);
      }
    } catch (SQLException e) {
      recordChain(e);
      throw e;
    }
  }

  public String[][] fetchBatch(long connId, String sql, int offset, int limit, int fetchSize) throws SQLException {
    Connection c = conns.get(connId);
    if (c == null) throw new SQLException("no conn", "08000", 33);
    try (Statement s = c.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
      s.setFetchSize(fetchSize);
      stmts.put(connId, s);
      try (ResultSet rs = s.executeQuery(sql)) {
        List<String[]> rows = new ArrayList<>();
        int skipped = 0;
        while (skipped < offset && rs.next()) skipped++;
        int n = 0;
        ResultSetMetaData m = rs.getMetaData();
        int cols = m.getColumnCount();
        while (n < limit && rs.next()) {
          String[] r = new String[cols];
          for (int i = 1; i <= cols; i++) {
            String v = rs.getString(i);
            r[i - 1] = rs.wasNull() ? null : v;
          }
          rows.add(r);
          n++;
        }
        return rows.toArray(new String[0][]);
      } finally {
        stmts.remove(connId);
      }
    } catch (SQLException e) {
      recordChain(e);
      throw e;
    }
  }

  public void cancel(long connId) throws SQLException {
    Statement s = stmts.get(connId);
    if (s != null) s.cancel();
  }

  public String poolStats(long poolId) {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) return "active=0 idle=0 wait=0";
    return "active=" + ds.getHikariPoolMXBean().getActiveConnections()
      + " idle=" + ds.getHikariPoolMXBean().getIdleConnections()
      + " wait=" + ds.getHikariPoolMXBean().getThreadsAwaitingConnection();
  }

  public String getErrorChain() { return lastError; }

  private void recordChain(SQLException e) {
    StringBuilder b = new StringBuilder();
    while (e != null) {
      b.append("SQLState=").append(e.getSQLState())
       .append(";code=").append(e.getErrorCode())
       .append(";msg=").append(e.getMessage()).append('\n');
      e = e.getNextException();
    }
    lastError = b.toString();
  }
}
