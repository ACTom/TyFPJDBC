package tyfpjdbc;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.math.BigDecimal;
import java.sql.*;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Bridge: the single state machine for TyFPJDBC.
 * Pools/connections/statements/cursors live here; Pascal holds Int64 handles.
 * Errors are ThreadLocal (no global lastError). Cancel is per-statement.
 * Values cross JNI as typed setters/getters; strings on the JNI boundary are
 * canonical forms, JDBC always uses the typed accessor matching the column.
 */
public class Bridge {
  public static final String VERSION = "0.9.0";

  private final AtomicLong ids = new AtomicLong(0);
  private final Map<Long, HikariDataSource> pools = new ConcurrentHashMap<>();
  private final Map<Long, ConnBox> conns = new ConcurrentHashMap<>();
  private final Map<Long, StmtBox> stmts = new ConcurrentHashMap<>();
  private final Map<Long, CursorBox> cursors = new ConcurrentHashMap<>();
  private final ThreadLocal<String> lastError = ThreadLocal.withInitial(() -> "");

  static final class ConnBox {
    Connection c;
    Map<String, Savepoint> sps = new HashMap<>();
  }
  static final class StmtBox {
    long connId;
    PreparedStatement ps;
    boolean isCall;
    Map<Integer, Integer> outParams = new HashMap<>();
  }
  static final class CursorBox {
    long stmtId;
    ResultSet rs;
    ResultSetMetaData meta;
    int pos;
    boolean[][] lastNulls;
  }

  public String getVersion() { return VERSION; }

  // ---- pools ----
  public long createPool(PoolCfg c) throws SQLException {
    if (c == null || c.jdbcUrl == null || c.jdbcUrl.isEmpty())
      throw new SQLException("bad url", "HY092", 40);
    HikariConfig h = new HikariConfig();
    h.setJdbcUrl(c.jdbcUrl);
    h.setUsername(c.user == null ? "" : c.user);
    h.setPassword(c.password == null ? "" : c.password);
    if (c.driverClass != null && !c.driverClass.isEmpty()) h.setDriverClassName(c.driverClass);
    h.setMaximumPoolSize(c.maximumPoolSize);
    h.setMinimumIdle(Math.min(c.minimumIdle, c.maximumPoolSize));
    h.setConnectionTimeout(c.connectionTimeoutMs);
    h.setMaxLifetime(c.maxLifetimeMs);
    h.setKeepaliveTime(c.keepaliveTimeMs);
    if (c.leakDetectionThresholdMs > 0) h.setLeakDetectionThreshold(c.leakDetectionThresholdMs);
    if (c.connectionTestQuery != null && !c.connectionTestQuery.isEmpty())
      h.setConnectionTestQuery(c.connectionTestQuery);
    h.setValidationTimeout(c.validationTimeoutMs);
    h.setReadOnly(c.readOnly);
    h.setAutoCommit(c.autoCommit);
    if (c.catalog != null && !c.catalog.isEmpty()) h.setCatalog(c.catalog);
    if (c.schema != null && !c.schema.isEmpty()) h.setSchema(c.schema);
    long id = ids.incrementAndGet();
    try {
      pools.put(id, new HikariDataSource(h));
    } catch (RuntimeException e) {
      SQLException s = new SQLException("pool create: " + e.getMessage(), "08001", 30);
      recordChain(s);
      throw s;
    }
    return id;
  }

  /** Flat JNI convenience: builds the PoolCfg server-side so Pascal never
   *  constructs Java objects field-by-field over JNI. */
  public long createPoolFlat(String jdbcUrl, String user, String pw, String driverClass,
      int maxPool, int minIdle, long connTimeoutMs, long maxLifetimeMs, long keepaliveMs,
      long leakMs, String testQuery, long validTimeoutMs, boolean readOnly, boolean autoCommit,
      String isolation, String catalog, String schema) throws SQLException {
    PoolCfg c = new PoolCfg(jdbcUrl == null ? "" : jdbcUrl, user == null ? "" : user,
        pw == null ? "" : pw, driverClass == null ? "" : driverClass, maxPool, minIdle);
    c.connectionTimeoutMs = connTimeoutMs;
    c.maxLifetimeMs = maxLifetimeMs;
    c.keepaliveTimeMs = keepaliveMs;
    c.leakDetectionThresholdMs = leakMs;
    c.connectionTestQuery = testQuery == null ? "" : testQuery;
    c.validationTimeoutMs = validTimeoutMs;
    c.readOnly = readOnly;
    c.autoCommit = autoCommit;
    c.isolationName = isolation == null ? "" : isolation;
    c.catalog = catalog == null ? "" : catalog;
    c.schema = schema == null ? "" : schema;
    return createPool(c);
  }

  public void destroyPool(long poolId) {
    HikariDataSource ds = pools.remove(poolId);
    if (ds != null) ds.close();
  }

  public int poolActive(long poolId) {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) return -1;
    return ds.getHikariPoolMXBean().getActiveConnections();
  }

  public int poolIdle(long poolId) {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) return -1;
    return ds.getHikariPoolMXBean().getIdleConnections();
  }

  public int poolWaiting(long poolId) {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) return -1;
    return ds.getHikariPoolMXBean().getThreadsAwaitingConnection();
  }

  /** Reserved leak slot: Hikari MXBean exposes no leak count; the pool is
   *  configured with leakDetectionThresholdMs (logs on leak) and this slot
   *  stays 0 so the structured record keeps a stable shape. */
  public int poolLeak(long poolId) {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) return -1;
    return 0;
  }

  // ---- connections ----
  public long borrowConn(long poolId) throws SQLException {
    HikariDataSource ds = pools.get(poolId);
    if (ds == null) {
      SQLException s = new SQLException("no pool", "HY000", 99);
      recordChain(s);
      throw s;
    }
    try {
      Connection c = ds.getConnection();
      ConnBox b = new ConnBox();
      b.c = c;
      long id = ids.incrementAndGet();
      conns.put(id, b);
      return id;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void closeConn(long connId) throws SQLException {
    ConnBox b = conns.remove(connId);
    if (b != null && b.c != null) {
      try { b.c.close(); } catch (SQLException e) { recordChain(e); throw e; }
    }
  }

  private ConnBox needConn(long connId) throws SQLException {
    ConnBox b = conns.get(connId);
    if (b == null || b.c == null) {
      SQLException s = new SQLException("no conn", "HY000", 99);
      recordChain(s);
      throw s;
    }
    return b;
  }

  public void setAutoCommit(long connId, boolean auto) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.setAutoCommit(auto); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void commit(long connId) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.commit(); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void rollback(long connId) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.rollback(); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public static boolean validSavepointName(String n) {
    return n != null && n.matches("[A-Za-z_][A-Za-z0-9_]{0,63}");
  }

  public void savepoint(long connId, String name) throws SQLException {
    if (!validSavepointName(name)) throw new SQLException("bad savepoint " + name, "HY092", 41);
    ConnBox b = needConn(connId);
    try { b.sps.put(name, b.c.setSavepoint(name)); }
    catch (SQLException e) { recordChain(e); throw e; }
  }

  public void rollbackTo(long connId, String name) throws SQLException {
    if (!validSavepointName(name)) throw new SQLException("bad savepoint " + name, "HY092", 41);
    ConnBox b = needConn(connId);
    Savepoint sp = b.sps.get(name);
    if (sp == null) throw new SQLException("unknown savepoint " + name, "HY000", 99);
    try { b.c.rollback(sp); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void releaseSavepoint(long connId, String name) throws SQLException {
    if (!validSavepointName(name)) throw new SQLException("bad savepoint " + name, "HY092", 41);
    ConnBox b = needConn(connId);
    Savepoint sp = b.sps.remove(name);
    if (sp == null) throw new SQLException("unknown savepoint " + name, "HY000", 99);
    try { b.c.releaseSavepoint(sp); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void setReadOnly(long connId, boolean ro) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.setReadOnly(ro); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void setCatalog(long connId, String v) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.setCatalog(v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void setSchema(long connId, String v) throws SQLException {
    ConnBox b = needConn(connId);
    try { b.c.setSchema(v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void setIsolation(long connId, String name) throws SQLException {
    ConnBox b = needConn(connId);
    int level;
    if ("READ_UNCOMMITTED".equals(name)) level = Connection.TRANSACTION_READ_UNCOMMITTED;
    else if ("READ_COMMITTED".equals(name)) level = Connection.TRANSACTION_READ_COMMITTED;
    else if ("REPEATABLE_READ".equals(name)) level = Connection.TRANSACTION_REPEATABLE_READ;
    else if ("SERIALIZABLE".equals(name)) level = Connection.TRANSACTION_SERIALIZABLE;
    else throw new SQLException("bad isolation " + String.valueOf(name), "HY092", 42);
    try { b.c.setTransactionIsolation(level); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public boolean isValid(long connId, int timeoutSecs) throws SQLException {
    ConnBox b = needConn(connId);
    try { return b.c.isValid(timeoutSecs); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public String getDatabaseMeta(long connId) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      DatabaseMetaData m = b.c.getMetaData();
      return m.getDatabaseProductName() + "|" + m.getDatabaseProductVersion() + "|" + m.getDriverName();
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  // ---- statements ----
  public long prepare(long connId, String sql) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      PreparedStatement ps = b.c.prepareStatement(sql, Statement.RETURN_GENERATED_KEYS);
      StmtBox sb = new StmtBox();
      sb.connId = connId; sb.ps = ps; sb.isCall = false;
      long id = ids.incrementAndGet();
      stmts.put(id, sb);
      return id;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public long prepareCall(long connId, String sql) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      CallableStatement cs = b.c.prepareCall(sql);
      StmtBox sb = new StmtBox();
      sb.connId = connId; sb.ps = cs; sb.isCall = true;
      long id = ids.incrementAndGet();
      stmts.put(id, sb);
      return id;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  private StmtBox needStmt(long stmtId) throws SQLException {
    StmtBox s = stmts.get(stmtId);
    if (s == null || s.ps == null) {
      SQLException e = new SQLException("no stmt", "HY000", 99);
      recordChain(e);
      throw e;
    }
    return s;
  }

  public void setTimeout(long stmtId, int secs) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setQueryTimeout(secs); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindLong(long stmtId, int idx, long v) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setLong(idx, v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindDouble(long stmtId, int idx, double v) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setDouble(idx, v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindBigDecimal(long stmtId, int idx, String v) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setBigDecimal(idx, new BigDecimal(v)); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindString(long stmtId, int idx, String v) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setString(idx, v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindDate(long stmtId, int idx, String iso) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setDate(idx, java.sql.Date.valueOf(iso)); } catch (Exception e) {
      SQLException s2 = new SQLException("bad date: " + iso, "HY092", 43);
      recordChain(s2); throw s2;
    }
  }

  public void bindTime(long stmtId, int idx, String iso) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setTime(idx, java.sql.Time.valueOf(iso)); } catch (Exception e) {
      SQLException s2 = new SQLException("bad time: " + iso, "HY092", 43);
      recordChain(s2); throw s2;
    }
  }

  public void bindTimestamp(long stmtId, int idx, String iso) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setTimestamp(idx, java.sql.Timestamp.valueOf(iso)); } catch (Exception e) {
      SQLException s2 = new SQLException("bad timestamp: " + iso, "HY092", 43);
      recordChain(s2); throw s2;
    }
  }

  public void bindBytes(long stmtId, int idx, byte[] v) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setBytes(idx, v); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void bindNull(long stmtId, int idx, int sqlType) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.setNull(idx, sqlType); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void addBatch(long stmtId) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { s.ps.addBatch(); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public int execUpdate(long stmtId) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try { return s.ps.executeUpdate(); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public int execBatch(long stmtId) throws SQLException {
    StmtBox s = needStmt(stmtId);
    ConnBox b = needConn(s.connId);
    boolean prevAuto;
    try { prevAuto = b.c.getAutoCommit(); } catch (SQLException e) { recordChain(e); throw e; }
    try {
      if (prevAuto) b.c.setAutoCommit(false);
      int total = 0;
      for (int n : s.ps.executeBatch()) {
        if (n >= 0) total += n;
        else if (n == Statement.SUCCESS_NO_INFO) total += 1;
      }
      b.c.commit();
      return total;
    } catch (SQLException e) {
      try { b.c.rollback(); } catch (SQLException ignored) {}
      recordChain(e);
      throw e;
    } finally {
      try { if (prevAuto) b.c.setAutoCommit(true); } catch (SQLException ignored) {}
    }
  }

  public String[] getGeneratedKeys(long stmtId) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try (ResultSet rs = s.ps.getGeneratedKeys()) {
      if (!rs.next()) return new String[0];
      ResultSetMetaData m = rs.getMetaData();
      int cols = m.getColumnCount();
      String[] out = new String[cols];
      for (int i = 1; i <= cols; i++) {
        String v = rs.getString(i);
        out[i - 1] = rs.wasNull() ? null : v;
      }
      return out;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public int execDirect(long connId, String sql) throws SQLException {
    return execDirectTimeout(connId, sql, 0);
  }

  public int execDirectTimeout(long connId, String sql, int timeoutSecs) throws SQLException {
    ConnBox b = needConn(connId);
    try (Statement s = b.c.createStatement()) {
      if (timeoutSecs > 0) s.setQueryTimeout(timeoutSecs);
      return s.executeUpdate(sql);
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void registerOut(long stmtId, int idx, int sqlType) throws SQLException {
    StmtBox s = needStmt(stmtId);
    if (!s.isCall) {
      SQLException e = new SQLException("not a call", "HY000", 99);
      recordChain(e);
      throw e;
    }
    try {
      ((CallableStatement) s.ps).registerOutParameter(idx, sqlType);
      s.outParams.put(idx, sqlType);
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public boolean execProc(long stmtId) throws SQLException {
    StmtBox s = needStmt(stmtId);
    if (!s.isCall) {
      SQLException e = new SQLException("not a call", "HY000", 99);
      recordChain(e);
      throw e;
    }
    try { return ((CallableStatement) s.ps).execute(); }
    catch (SQLException e) { recordChain(e); throw e; }
  }

  public String getOutValue(long stmtId, int idx) throws SQLException {
    StmtBox s = needStmt(stmtId);
    if (!s.isCall) {
      SQLException e = new SQLException("not a call", "HY000", 99);
      recordChain(e);
      throw e;
    }
    try {
      String v = ((CallableStatement) s.ps).getString(idx);
      return ((CallableStatement) s.ps).wasNull() ? null : v;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public void cancel(long stmtId) throws SQLException {
    StmtBox s = stmts.get(stmtId);
    if (s != null && s.ps != null) {
      try { s.ps.cancel(); } catch (SQLException e) { recordChain(e); throw e; }
    }
  }

  public void closeStmt(long stmtId) {
    StmtBox s = stmts.remove(stmtId);
    if (s != null && s.ps != null) { try { s.ps.close(); } catch (SQLException ignored) {} }
  }

  // ---- cursors (forward-only windows) ----
  public long queryOpen(long stmtId, int fetchSize) throws SQLException {
    StmtBox s = needStmt(stmtId);
    try {
      s.ps.setFetchSize(fetchSize);
      ResultSet rs = s.ps.executeQuery();
      CursorBox cb = new CursorBox();
      cb.stmtId = stmtId; cb.rs = rs; cb.meta = rs.getMetaData(); cb.pos = 0;
      long id = ids.incrementAndGet();
      cursors.put(id, cb);
      return id;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  private CursorBox needCursor(long cursorId) throws SQLException {
    CursorBox c = cursors.get(cursorId);
    if (c == null || c.rs == null) {
      SQLException e = new SQLException("no cursor", "HY000", 99);
      recordChain(e);
      throw e;
    }
    return c;
  }

  public int cursorCols(long cursorId) throws SQLException {
    CursorBox c = needCursor(cursorId);
    try { return c.meta.getColumnCount(); } catch (SQLException e) { recordChain(e); throw e; }
  }

  public String[] cursorNames(long cursorId) throws SQLException {
    CursorBox c = needCursor(cursorId);
    try {
      int n = c.meta.getColumnCount();
      String[] out = new String[n];
      for (int i = 1; i <= n; i++) out[i - 1] = c.meta.getColumnLabel(i);
      return out;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public String[] cursorTypeNames(long cursorId) throws SQLException {
    CursorBox c = needCursor(cursorId);
    try {
      int n = c.meta.getColumnCount();
      String[] out = new String[n];
      for (int i = 1; i <= n; i++) out[i - 1] = c.meta.getColumnTypeName(i);
      return out;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public int[] cursorTypeCodes(long cursorId) throws SQLException {
    CursorBox c = needCursor(cursorId);
    try {
      int n = c.meta.getColumnCount();
      int[] out = new int[n];
      for (int i = 1; i <= n; i++) out[i - 1] = c.meta.getColumnType(i);
      return out;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  /** Forward-only window: returns up to `size` next rows, typed getters per column. */
  public String[][] fetchWindow(long cursorId, int size) throws SQLException {
    CursorBox c = needCursor(cursorId);
    try {
      int cols = c.meta.getColumnCount();
      int[] codes = new int[cols];
      for (int i = 1; i <= cols; i++) codes[i - 1] = c.meta.getColumnType(i);
      List<String[]> rows = new ArrayList<>();
      List<boolean[]> nulls = new ArrayList<>();
      int n = 0;
      while (n < size && c.rs.next()) {
        String[] r = new String[cols];
        boolean[] nb = new boolean[cols];
        for (int i = 1; i <= cols; i++) {
          String v;
          boolean wasNull;
          switch (codes[i - 1]) {
            case Types.BIGINT: {
              long lv = c.rs.getLong(i); wasNull = c.rs.wasNull(); v = wasNull ? null : Long.toString(lv); break;
            }
            case Types.INTEGER: case Types.SMALLINT: case Types.TINYINT: {
              int iv = c.rs.getInt(i); wasNull = c.rs.wasNull(); v = wasNull ? null : Integer.toString(iv); break;
            }
            case Types.NUMERIC: case Types.DECIMAL: {
              BigDecimal bd = c.rs.getBigDecimal(i); wasNull = (bd == null); v = wasNull ? null : bd.toPlainString(); break;
            }
            case Types.FLOAT: case Types.REAL: case Types.DOUBLE: {
              double dv = c.rs.getDouble(i); wasNull = c.rs.wasNull(); v = wasNull ? null : Double.toString(dv); break;
            }
            case Types.BOOLEAN: case Types.BIT: {
              boolean bv = c.rs.getBoolean(i); wasNull = c.rs.wasNull(); v = wasNull ? null : (bv ? "1" : "0"); break;
            }
            case Types.DATE: {
              java.sql.Date d = c.rs.getDate(i); wasNull = (d == null); v = wasNull ? null : d.toString(); break;
            }
            case Types.TIME: {
              Time t = c.rs.getTime(i); wasNull = (t == null); v = wasNull ? null : t.toString(); break;
            }
            case Types.TIMESTAMP: {
              Timestamp ts = c.rs.getTimestamp(i); wasNull = (ts == null); v = wasNull ? null : ts.toString(); break;
            }
            case Types.BINARY: case Types.VARBINARY: case Types.LONGVARBINARY: case Types.BLOB: {
              byte[] by = c.rs.getBytes(i); wasNull = (by == null); v = wasNull ? null : ("<blob:" + by.length + ">"); break;
            }
            default: {
              String sv = c.rs.getString(i); wasNull = c.rs.wasNull(); v = wasNull ? null : sv; break;
            }
          }
          r[i - 1] = v;
          nb[i - 1] = wasNull;
        }
        rows.add(r);
        nulls.add(nb);
        n++;
        c.pos++;
      }
      c.lastNulls = nulls.toArray(new boolean[0][]);
      return rows.toArray(new String[0][]);
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public boolean[][] fetchLastNulls(long cursorId) throws SQLException {
    CursorBox c = needCursor(cursorId);
    if (c.lastNulls == null) return new boolean[0][];
    return c.lastNulls;
  }

  public void closeCursor(long cursorId) {
    CursorBox c = cursors.remove(cursorId);
    if (c != null && c.rs != null) { try { c.rs.close(); } catch (SQLException ignored) {} }
  }

  // ---- metadata ----
  public String[][] getTables(long connId, String table) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      DatabaseMetaData m = b.c.getMetaData();
      List<String[]> out = new ArrayList<>();
      try (ResultSet rs = m.getTables(null, null, table == null ? "%" : table, new String[]{"TABLE", "VIEW"})) {
        while (rs.next()) out.add(new String[]{rs.getString("TABLE_NAME"), rs.getString("TABLE_TYPE")});
      }
      return out.toArray(new String[0][]);
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public String[][] getColumns(long connId, String table) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      DatabaseMetaData m = b.c.getMetaData();
      List<String[]> out = new ArrayList<>();
      try (ResultSet rs = m.getColumns(null, null, table, "%")) {
        while (rs.next()) out.add(new String[]{rs.getString("COLUMN_NAME"), rs.getString("TYPE_NAME"), rs.getString("IS_NULLABLE")});
      }
      return out.toArray(new String[0][]);
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public String[] getPrimaryKeys(long connId, String table) throws SQLException {
    ConnBox b = needConn(connId);
    try {
      DatabaseMetaData m = b.c.getMetaData();
      List<String[]> tmp = new ArrayList<>();
      try (ResultSet rs = m.getPrimaryKeys(null, null, table)) {
        while (rs.next()) tmp.add(new String[]{rs.getString("KEY_SEQ"), rs.getString("COLUMN_NAME")});
      }
      tmp.sort(Comparator.comparing(a -> a[0]));
      String[] out = new String[tmp.size()];
      for (int i = 0; i < tmp.size(); i++) out[i] = tmp.get(i)[1];
      return out;
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  // ---- blobs (buffered 64KB stream copy on the JDBC side) ----
  public int writeBlob(long connId, String sql, byte[] data) throws SQLException {
    ConnBox b = needConn(connId);
    try (PreparedStatement ps = b.c.prepareStatement(sql)) {
      if (data == null) ps.setNull(1, Types.BLOB);
      else if (data.length > 1024 * 1024) ps.setBinaryStream(1, new java.io.ByteArrayInputStream(data), data.length);
      else ps.setBytes(1, data);
      return ps.executeUpdate();
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public byte[] fetchBlob(long connId, String sql) throws SQLException {
    ConnBox b = needConn(connId);
    try (Statement s = b.c.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
         ResultSet rs = s.executeQuery(sql)) {
      if (!rs.next()) return null;
      try (InputStream in = rs.getBinaryStream(1);
           ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
        if (in == null) return null;
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) >= 0) bos.write(buf, 0, n);
        return bos.toByteArray();
      } catch (java.io.IOException e) {
        SQLException s2 = new SQLException("blob read: " + e.getMessage(), "HY000", 99);
        recordChain(s2); throw s2;
      }
    } catch (SQLException e) { recordChain(e); throw e; }
  }

  public long heapUsedBytes() {
    return java.lang.management.ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed();
  }

  public long heapMaxBytes() {
    return java.lang.management.ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getMax();
  }

  public String getErrorChain() { return lastError.get(); }

  private void recordChain(SQLException e) {
    StringBuilder b = new StringBuilder();
    while (e != null) {
      b.append("SQLState=").append(e.getSQLState())
       .append(";code=").append(e.getErrorCode())
       .append(";msg=").append(e.getMessage()).append('\n');
      e = e.getNextException();
    }
    lastError.set(b.toString());
  }
}
