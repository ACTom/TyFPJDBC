package tyfpjdbc;

/** V2 pool/connection configuration. Public fields keep JNI signatures flat. */
public class PoolCfg {
  public String jdbcUrl = "";
  public String user = "";
  public String password = "";
  public String driverClass = "";
  public int maximumPoolSize = 10;
  public int minimumIdle = 2;
  public long connectionTimeoutMs = 30000;
  public long maxLifetimeMs = 1800000;
  public long keepaliveTimeMs = 30000;
  public long leakDetectionThresholdMs = 0;
  public String connectionTestQuery = "SELECT 1";
  public long validationTimeoutMs = 5000;
  public boolean readOnly = false;
  public boolean autoCommit = true;
  public String isolationName = "READ_COMMITTED";
  public String catalog = "";
  public String schema = "";
  public long networkTimeoutMs = 0;

  public PoolCfg() {}

  public PoolCfg(String jdbcUrl, String user, String password, String driverClass,
                 int maximumPoolSize, int minimumIdle) {
    this.jdbcUrl = jdbcUrl;
    this.user = user;
    this.password = password;
    this.driverClass = driverClass;
    this.maximumPoolSize = maximumPoolSize;
    this.minimumIdle = minimumIdle;
  }
}
