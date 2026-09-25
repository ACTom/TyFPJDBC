program TestRealWorld;

{$mode objfpc}{$H+}

{ Real-world SQL shapes modeled on large open-source projects:
  WordPress (wp_users / wp_posts / wp_postmeta / wp_comments),
  shop order/inventory flow (customers / orders / order_items / products),
  RBAC (app_users / roles / user_roles),
  Odoo 16 (sale_order / sale_order_line / product_product / res_partner /
    stock_quant / account_move_line / mrp_bom_line / crm_lead),
  ERPNext v15 (`tabSales Order` / `tabSales Order Item` / tabCustomer),
  Saleor 3.x (order_order / order_orderline / discount_voucher),
  SuiteCRM (opportunities / opportunities_contacts / contacts).
  Parser-level: every value must become a ? binding, identifiers stay inline. }

uses
  SysUtils, Classes, TyFPJDBC.Command, TyFPJDBC.Script;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Ok(const Name: string);
begin
  Inc(PassCount);
  WriteLn('PASS: ', Name);
end;

procedure Ng(const Name, Detail: string);
begin
  Inc(FailCount);
  WriteLn('FAIL: ', Name, ' -- ', Detail);
end;

procedure CheckParse(const Name, SQL, WantSql: string; const WantParams: array of string);
var
  r: TRewriteResult;
  i: Integer;
begin
  r := RewriteNamedParams(SQL);
  if r.JdbcSql <> WantSql then
    Ng(Name + '-sql', 'got: ' + r.JdbcSql)
  else
    Ok(Name + '-sql');
  if Length(r.ParamOrder) <> Length(WantParams) then
    Ng(Name + '-count', 'got ' + IntToStr(Length(r.ParamOrder)) + ' want ' + IntToStr(Length(WantParams)))
  else
  begin
    Ok(Name + '-count');
    for i := 0 to High(WantParams) do
      if r.ParamOrder[i] <> WantParams[i] then
      begin
        Ng(Name + '-order', 'pos ' + IntToStr(i) + ' got ' + r.ParamOrder[i]);
        Exit;
      end;
    Ok(Name + '-order');
  end;
end;

begin
  { 1. Wide-table DDL passes through untouched, zero params }
  CheckParse('wide-ddl',
    'CREATE TABLE wp_posts(id BIGINT PRIMARY KEY, author_id BIGINT, title VARCHAR(255), body TEXT, excerpt TEXT, status VARCHAR(20), created TIMESTAMP, modified TIMESTAMP, views INT DEFAULT 0)',
    'CREATE TABLE wp_posts(id BIGINT PRIMARY KEY, author_id BIGINT, title VARCHAR(255), body TEXT, excerpt TEXT, status VARCHAR(20), created TIMESTAMP, modified TIMESTAMP, views INT DEFAULT 0)',
    []);

  { 2. Wide insert, 6 named params in order }
  CheckParse('wide-insert',
    'INSERT INTO wp_posts(id, author_id, title, body, status, created) VALUES(:id, :author, :title, :body, :status, :created)',
    'INSERT INTO wp_posts(id, author_id, title, body, status, created) VALUES(?, ?, ?, ?, ?, ?)',
    ['id', 'author', 'title', 'body', 'status', 'created']);

  { 3. Three-table join (posts -> users -> postmeta) }
  CheckParse('three-join',
    'SELECT p.id, p.title, u.login, m.mval FROM wp_posts p JOIN wp_users u ON u.id=p.author_id JOIN wp_postmeta m ON m.post_id=p.id WHERE p.status=:status AND u.id=:uid',
    'SELECT p.id, p.title, u.login, m.mval FROM wp_posts p JOIN wp_users u ON u.id=p.author_id JOIN wp_postmeta m ON m.post_id=p.id WHERE p.status=? AND u.id=?',
    ['status', 'uid']);

  { 4. LEFT JOIN + GROUP BY + HAVING }
  CheckParse('group-having',
    'SELECT u.id, u.login, COUNT(p.id) AS n FROM wp_users u LEFT JOIN wp_posts p ON p.author_id=u.id WHERE u.id>:minid GROUP BY u.id, u.login HAVING COUNT(p.id)>:minc',
    'SELECT u.id, u.login, COUNT(p.id) AS n FROM wp_users u LEFT JOIN wp_posts p ON p.author_id=u.id WHERE u.id>? GROUP BY u.id, u.login HAVING COUNT(p.id)>?',
    ['minid', 'minc']);

  { 5. Subquery IN }
  CheckParse('subquery-in',
    'SELECT id, title FROM wp_posts WHERE id IN (SELECT post_id FROM wp_postmeta WHERE mkey=:mk AND mval=:mv) AND status=:st',
    'SELECT id, title FROM wp_posts WHERE id IN (SELECT post_id FROM wp_postmeta WHERE mkey=? AND mval=?) AND status=?',
    ['mk', 'mv', 'st']);

  { 6. CTE }
  CheckParse('cte',
    'WITH recent AS (SELECT id FROM wp_posts WHERE created>:since) SELECT p.id, p.title FROM wp_posts p JOIN recent r ON r.id=p.id WHERE p.status=:st',
    'WITH recent AS (SELECT id FROM wp_posts WHERE created>?) SELECT p.id, p.title FROM wp_posts p JOIN recent r ON r.id=p.id WHERE p.status=?',
    ['since', 'st']);

  { 7. Window function }
  CheckParse('window',
    'SELECT id, title, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY created DESC) AS rn FROM wp_posts WHERE status=:st',
    'SELECT id, title, ROW_NUMBER() OVER (PARTITION BY author_id ORDER BY created DESC) AS rn FROM wp_posts WHERE status=?',
    ['st']);

  { 8. Paged listing }
  CheckParse('paged',
    'SELECT id, title FROM wp_posts WHERE status=:st ORDER BY created DESC LIMIT :lim OFFSET :off',
    'SELECT id, title FROM wp_posts WHERE status=? ORDER BY created DESC LIMIT ? OFFSET ?',
    ['st', 'lim', 'off']);

  { 9. Multi LIKE with ESCAPE }
  CheckParse('multi-like',
    'SELECT id FROM products WHERE name LIKE :kw ESCAPE ''\'' AND sku LIKE :sk ESCAPE ''\''',
    'SELECT id FROM products WHERE name LIKE ? ESCAPE ''\'' AND sku LIKE ? ESCAPE ''\''',
    ['kw', 'sk']);

  { 10. BETWEEN }
  CheckParse('between',
    'SELECT id FROM orders WHERE created BETWEEN :d1 AND :d2 AND total>:min',
    'SELECT id FROM orders WHERE created BETWEEN ? AND ? AND total>?',
    ['d1', 'd2', 'min']);

  { 11. IS NULL guard }
  CheckParse('is-null',
    'SELECT id FROM wp_posts WHERE deleted_at IS NULL AND status=:st',
    'SELECT id FROM wp_posts WHERE deleted_at IS NULL AND status=?',
    ['st']);

  { 12. Inventory decrement, repeated param bound 3x }
  CheckParse('decrement',
    'UPDATE inventory SET qty=qty-:n WHERE sku=:sku AND qty>=:n',
    'UPDATE inventory SET qty=qty-? WHERE sku=? AND qty>=?',
    ['n', 'sku', 'n']);

  { 13. Session cleanup delete }
  CheckParse('delete-old',
    'DELETE FROM sessions WHERE last_seen<:cutoff',
    'DELETE FROM sessions WHERE last_seen<?',
    ['cutoff']);

  { 14. DDL migrate untouched }
  CheckParse('alter-add',
    'ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0',
    'ALTER TABLE wp_posts ADD COLUMN views INT DEFAULT 0',
    []);
  CheckParse('create-index',
    'CREATE INDEX idx_posts_author ON wp_posts(author_id, created)',
    'CREATE INDEX idx_posts_author ON wp_posts(author_id, created)',
    []);

  { 15. Upsert }
  CheckParse('upsert',
    'INSERT INTO products(id, name) VALUES(:id, :nm) ON CONFLICT(id) DO UPDATE SET name=:nm',
    'INSERT INTO products(id, name) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET name=?',
    ['id', 'nm', 'nm']);

  { 16. Identifier stays inline, values still bind (macro concept folded
    into dialect quoting; table names are never bound params). }
  CheckParse('macro-chain',
    'SELECT * FROM wp_posts WHERE id=:id',
    'SELECT * FROM wp_posts WHERE id=?',
    ['id']);

  { 17. Rewrite never treats hostile text as SQL: hostile literals pass
    through as bindings' source text, output keeps one ? per name. }
  CheckParse('macro-inject-shape',
    'SELECT * FROM t WHERE a=:id AND b=:drop',
    'SELECT * FROM t WHERE a=? AND b=?',
    ['id', 'drop']);

  { 18. Migration script split: 4 statements, semicolons in strings ignored }
  with TJDBCScript.Split('CREATE TABLE a(id INT); CREATE INDEX i ON a(id); INSERT INTO a VALUES('';''); UPDATE a SET id=1 WHERE id=2;') do
  try
    if Count <> 4 then
      Ng('script-migrate-count', 'got ' + IntToStr(Count))
    else
      Ok('script-migrate-count');
  finally
    Free;
  end;

  { 19. Odoo sales funnel: 4-table join + aggregate bucket + GROUP BY + HAVING.
    NOTE: the bucket CASE must sit on an aggregate (SUM), not on a bare
    non-grouped column -- H2/PostgreSQL strict GROUP BY rejects the latter,
    and reports bucket on the aggregated measure, not on a source row. }
  CheckParse('odoo-funnel',
    'SELECT p.name, CASE WHEN SUM(l.price_subtotal)>:big THEN ''VIP'' WHEN SUM(l.price_subtotal)>:mid THEN ''STD'' ELSE ''SMB'' END AS seg, COUNT(l.id) AS lines, SUM(l.price_subtotal) AS amt FROM sale_order o JOIN sale_order_line l ON l.order_id=o.id JOIN product_product p ON p.id=l.product_id JOIN res_partner r ON r.id=o.partner_id WHERE o.state=:st AND o.date_order BETWEEN :d1 AND :d2 GROUP BY p.name HAVING SUM(l.price_subtotal)>:min',
    'SELECT p.name, CASE WHEN SUM(l.price_subtotal)>? THEN ''VIP'' WHEN SUM(l.price_subtotal)>? THEN ''STD'' ELSE ''SMB'' END AS seg, COUNT(l.id) AS lines, SUM(l.price_subtotal) AS amt FROM sale_order o JOIN sale_order_line l ON l.order_id=o.id JOIN product_product p ON p.id=l.product_id JOIN res_partner r ON r.id=o.partner_id WHERE o.state=? AND o.date_order BETWEEN ? AND ? GROUP BY p.name HAVING SUM(l.price_subtotal)>?',
    ['big', 'mid', 'st', 'd1', 'd2', 'min']);

  { 20. Odoo on-hand stock: correlated EXISTS + NOT EXISTS }
  CheckParse('odoo-stock',
    'SELECT p.default_code FROM product_product p WHERE EXISTS(SELECT 1 FROM stock_quant q WHERE q.product_id=p.id AND q.location_id=:loc AND q.quantity>:zero) AND NOT EXISTS(SELECT 1 FROM stock_move m WHERE m.product_id=p.id AND m.state=:cancelled)',
    'SELECT p.default_code FROM product_product p WHERE EXISTS(SELECT 1 FROM stock_quant q WHERE q.product_id=p.id AND q.location_id=? AND q.quantity>?) AND NOT EXISTS(SELECT 1 FROM stock_move m WHERE m.product_id=p.id AND m.state=?)',
    ['loc', 'zero', 'cancelled']);

  { 21. Odoo trial balance: UNION ALL + aggregate }
  CheckParse('odoo-trial',
    'SELECT a.code, SUM(l.debit) AS dr, SUM(l.credit) AS cr FROM account_move_line l JOIN account_account a ON a.id=l.account_id WHERE l.date BETWEEN :d1 AND :d2 GROUP BY a.code UNION ALL SELECT ''TOTAL'', SUM(debit), SUM(credit) FROM account_move_line WHERE date BETWEEN :d1 AND :d2',
    'SELECT a.code, SUM(l.debit) AS dr, SUM(l.credit) AS cr FROM account_move_line l JOIN account_account a ON a.id=l.account_id WHERE l.date BETWEEN ? AND ? GROUP BY a.code UNION ALL SELECT ''TOTAL'', SUM(debit), SUM(credit) FROM account_move_line WHERE date BETWEEN ? AND ?',
    ['d1', 'd2', 'd1', 'd2']);

  { 22. Odoo MRP BOM explosion: recursive CTE }
  CheckParse('odoo-bom',
    'WITH RECURSIVE bom(id, parent, qty) AS (SELECT id, 0, product_qty FROM mrp_bom_line WHERE bom_id=:top UNION ALL SELECT l.id, b.id, l.product_qty*b.qty FROM mrp_bom_line l JOIN bom b ON b.id=l.bom_id) SELECT id, SUM(qty) FROM bom GROUP BY id',
    'WITH RECURSIVE bom(id, parent, qty) AS (SELECT id, 0, product_qty FROM mrp_bom_line WHERE bom_id=? UNION ALL SELECT l.id, b.id, l.product_qty*b.qty FROM mrp_bom_line l JOIN bom b ON b.id=l.bom_id) SELECT id, SUM(qty) FROM bom GROUP BY id',
    ['top']);

  { 23. Odoo CRM stage funnel: self-join team + date bucket }
  CheckParse('odoo-crm',
    'SELECT s.name AS stage, u.login AS owner, COUNT(l.id) AS n, AVG(l.expected_revenue) AS avgrev FROM crm_lead l JOIN crm_stage s ON s.id=l.stage_id LEFT JOIN res_users ou ON ou.id=l.user_id LEFT JOIN res_users m ON m.id=ou.manager_id JOIN wp_users u ON u.id=ou.id WHERE l.type=:tp AND l.create_date>=:since GROUP BY s.name, u.login ORDER BY n DESC',
    'SELECT s.name AS stage, u.login AS owner, COUNT(l.id) AS n, AVG(l.expected_revenue) AS avgrev FROM crm_lead l JOIN crm_stage s ON s.id=l.stage_id LEFT JOIN res_users ou ON ou.id=l.user_id LEFT JOIN res_users m ON m.id=ou.manager_id JOIN wp_users u ON u.id=ou.id WHERE l.type=? AND l.create_date>=? GROUP BY s.name, u.login ORDER BY n DESC',
    ['tp', 'since']);

  { 24. ERPNext: backtick DocTypes + status + window rank }
  CheckParse('erpnext-rank',
    'SELECT o.customer, o.grand_total, RANK() OVER (PARTITION BY o.customer ORDER BY o.grand_total DESC) AS rk FROM `tabSales Order` o JOIN `tabSales Order Item` i ON i.parent=o.name WHERE o.docstatus=:ds AND o.transaction_date>=:since',
    'SELECT o.customer, o.grand_total, RANK() OVER (PARTITION BY o.customer ORDER BY o.grand_total DESC) AS rk FROM `tabSales Order` o JOIN `tabSales Order Item` i ON i.parent=o.name WHERE o.docstatus=? AND o.transaction_date>=?',
    ['ds', 'since']);

  { 25. ERPNext stock ledger: 5-table join + IN list shape }
  CheckParse('erpnext-ledger',
    'SELECT b.item_code, b.warehouse, SUM(b.actual_qty) FROM `tabStock Ledger Entry` b JOIN tabItem i ON i.name=b.item_code JOIN tabWarehouse w ON w.name=b.warehouse JOIN tabCompany c ON c.name=b.company JOIN tabUOM u ON u.name=i.stock_uom WHERE b.posting_date BETWEEN :d1 AND :d2 AND b.is_cancelled=:no GROUP BY b.item_code, b.warehouse',
    'SELECT b.item_code, b.warehouse, SUM(b.actual_qty) FROM `tabStock Ledger Entry` b JOIN tabItem i ON i.name=b.item_code JOIN tabWarehouse w ON w.name=b.warehouse JOIN tabCompany c ON c.name=b.company JOIN tabUOM u ON u.name=i.stock_uom WHERE b.posting_date BETWEEN ? AND ? AND b.is_cancelled=? GROUP BY b.item_code, b.warehouse',
    ['d1', 'd2', 'no']);

  { 26. Saleor: order + voucher LEFT JOIN + currency CASE }
  CheckParse('saleor-voucher',
    'SELECT o.number, o.total_gross_amount, CASE WHEN v.id IS NULL THEN 0 ELSE v.discount_value END AS disc FROM order_order o LEFT JOIN order_orderdiscounts d ON d.order_id=o.id LEFT JOIN discount_voucher v ON v.id=d.voucher_id WHERE o.status=:st AND o.created_at>=:since ORDER BY o.created_at DESC LIMIT :lim',
    'SELECT o.number, o.total_gross_amount, CASE WHEN v.id IS NULL THEN 0 ELSE v.discount_value END AS disc FROM order_order o LEFT JOIN order_orderdiscounts d ON d.order_id=o.id LEFT JOIN discount_voucher v ON v.id=d.voucher_id WHERE o.status=? AND o.created_at>=? ORDER BY o.created_at DESC LIMIT ?',
    ['st', 'since', 'lim']);

  { 27. SuiteCRM: m2m bridge + DISTINCT }
  CheckParse('suitecrm-m2m',
    'SELECT DISTINCT o.id, o.name, o.amount, c.first_name FROM opportunities o JOIN opportunities_contacts oc ON oc.opportunity_id=o.id JOIN contacts c ON c.id=oc.contact_id WHERE o.sales_stage=:stage AND o.date_closed BETWEEN :d1 AND :d2',
    'SELECT DISTINCT o.id, o.name, o.amount, c.first_name FROM opportunities o JOIN opportunities_contacts oc ON oc.opportunity_id=o.id JOIN contacts c ON c.id=oc.contact_id WHERE o.sales_stage=? AND o.date_closed BETWEEN ? AND ?',
    ['stage', 'd1', 'd2']);

  { 28. INSERT..SELECT stock move (ERP posting shape) }
  CheckParse('insert-select',
    'INSERT INTO stock_move(product_id, qty, state) SELECT product_id, :qty, :st FROM product_product WHERE default_code=:code',
    'INSERT INTO stock_move(product_id, qty, state) SELECT product_id, ?, ? FROM product_product WHERE default_code=?',
    ['qty', 'st', 'code']);

  { 29. 5-table order detail page }
  CheckParse('five-join',
    'SELECT o.id, r.name, p.default_code, l.qty, w.name FROM sale_order o JOIN res_partner r ON r.id=o.partner_id JOIN sale_order_line l ON l.order_id=o.id JOIN product_product p ON p.id=l.product_id JOIN stock_warehouse w ON w.id=:wh WHERE o.state=:st ORDER BY o.id LIMIT :lim OFFSET :off',
    'SELECT o.id, r.name, p.default_code, l.qty, w.name FROM sale_order o JOIN res_partner r ON r.id=o.partner_id JOIN sale_order_line l ON l.order_id=o.id JOIN product_product p ON p.id=l.product_id JOIN stock_warehouse w ON w.id=? WHERE o.state=? ORDER BY o.id LIMIT ? OFFSET ?',
    ['wh', 'st', 'lim', 'off']);

  WriteLn('TOTAL pass=', PassCount, ' fail=', FailCount);
  if FailCount > 0 then
    Halt(1);
end.
