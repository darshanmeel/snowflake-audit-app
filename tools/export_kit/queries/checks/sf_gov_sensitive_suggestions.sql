-- query_id: sf_gov_sensitive_suggestions
-- title: Columns whose names look sensitive but carry no sensitive tag
-- domain: governance_access   tier: standard
-- entity: columns = database_name, schema_name, table_name, column_name
-- windowed: no
-- reads: SNOWFLAKE.ACCOUNT_USAGE.COLUMNS, SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES,
--   SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
-- requires: IMPORTED PRIVILEGES on the SNOWFLAKE database
-- params: :row_cap (default 200000) rows: the export keeps at most this many, identifiers first
-- confidence: needs_confirmation
-- confidence_note: Not yet run on a live account. Name matching only; no column value is read.
-- read_this: one row = one live column with no sensitive tag whose name matches a pattern for one of
--   Snowflake's semantic categories (EMAIL, PHONE_NUMBER, NATIONAL_IDENTIFIER ...) or CREDENTIAL (not a
--   Snowflake category: passwords, tokens, secrets). suggested_category and privacy_category are what
--   SNOWFLAKE.CORE.SEMANTIC_CATEGORY and PRIVACY_CATEGORY would most likely say; confidence is high when
--   the name is unambiguous (EMAIL, SSN, IBAN), medium when it often is (ADDRESS, ACCOUNT_NUMBER), low for
--   quasi-identifiers that are often harmless (CITY, AGE). Snowflake classification, which reads the data,
--   confirms it.
-- healthy: status = OK when nothing that looks like an identifier is untagged.
-- investigate_if: WARN for an untagged column that looks like an IDENTIFIER or SENSITIVE with high or
--   medium confidence or a credential; OK for the rest, listed as a suggestion.
-- actions: 1) run Snowflake classification on the tables listed (CALL SYSTEM$CLASSIFY with auto_tag, or
--   a classification profile on the database) so the system tags are set from the data (serverless
--   credits); 2) put masking policies on the classification tags (config)
-- next: sf_gov_classification_coverage
-- caveats: names lie both ways: a column called C7 holding emails is missed, and NAME_ID is flagged.
--   Tags seen are direct tags on the column only; the role sees only the columns of objects it can
--   access. Classification results the account already has are in sf_gov_classification_coverage.
WITH -- Columns marked sensitive by a tag (Snowflake's SEMANTIC_CATEGORY / PRIVACY_CATEGORY system tags, or a
-- custom tag whose name says PII, sensitive, confidential, PHI, PCI, GDPR, personal or restricted), with
-- whether a masking policy covers them directly or through a tag on the column, table, schema or database.
sf_gov_tag_refs AS (
  SELECT UPPER(tag_database) AS tag_database, UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name,
         tag_value, UPPER(domain) AS domain, UPPER(object_database) AS object_database,
         UPPER(object_schema) AS object_schema, UPPER(object_name) AS object_name, UPPER(column_name) AS column_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
  WHERE object_deleted IS NULL
),
-- Which tags mean "sensitive": Snowflake's classification system tags (any value but INSENSITIVE) or a custom
-- tag whose name says so (short acronyms as whole words only, so GEOGRAPHIC is not PHI) with a value that
-- is not a "no" (FALSE, NO, NONE, PUBLIC, INSENSITIVE ...).
sf_gov_sensitive_tagged AS (
  SELECT object_database AS database_name, object_schema AS schema_name, object_name AS table_name, column_name,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'PRIVACY_CATEGORY', UPPER(tag_value), NULL)) AS privacy_category,
         MAX(IFF(tag_database = 'SNOWFLAKE' AND tag_name = 'SEMANTIC_CATEGORY', UPPER(tag_value), NULL)) AS semantic_category,
         LISTAGG(DISTINCT IFF(tag_database = 'SNOWFLAKE', NULL, tag_database || '.' || tag_schema || '.' || tag_name
                 || COALESCE('=' || tag_value, '')), ', ') AS custom_tags,
         COALESCE(BOOLOR_AGG(tag_database <> 'SNOWFLAKE'
                  AND REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI)([^A-Z0-9].*|$)')), FALSE) AS has_pii_tag
  FROM sf_gov_tag_refs
  WHERE domain = 'COLUMN'
    AND ((tag_database = 'SNOWFLAKE' AND tag_schema = 'CORE' AND tag_name IN ('PRIVACY_CATEGORY', 'SEMANTIC_CATEGORY')
          AND UPPER(COALESCE(tag_value, '')) <> 'INSENSITIVE')
         OR (tag_database <> 'SNOWFLAKE'
             AND (REGEXP_LIKE(tag_name, '(^|.*[^A-Z0-9])(PII|PHI|PCI|GDPR)([^A-Z0-9].*|$)')
                  OR (REGEXP_LIKE(tag_name, '.*(SENSITIV|CONFIDENTIAL|PERSONAL|RESTRICTED).*')
                      AND NOT REGEXP_LIKE(tag_name, '.*(INSENSITIV|NON.?SENSITIV|NOT.?SENSITIV).*')))
             AND UPPER(COALESCE(tag_value, '')) NOT IN
                 ('FALSE', 'NO', 'N', 'NONE', 'PUBLIC', 'INSENSITIVE', 'NON_SENSITIVE', 'NON-SENSITIVE', 'NOT_SENSITIVE', '0')))
  GROUP BY 1, 2, 3, 4
),
sf_gov_policy_refs AS (
  SELECT policy_kind, UPPER(policy_db || '.' || policy_schema || '.' || policy_name) AS policy_fqn,
         UPPER(ref_database_name) AS ref_database_name, UPPER(ref_schema_name) AS ref_schema_name,
         UPPER(ref_entity_name) AS ref_entity_name, UPPER(ref_entity_domain) AS ref_entity_domain,
         UPPER(ref_column_name) AS ref_column_name, UPPER(tag_database) AS tag_database,
         UPPER(tag_schema) AS tag_schema, UPPER(tag_name) AS tag_name
  FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
  -- A policy attached but not ACTIVE (for example two masks on one column) does not protect anything.
  WHERE UPPER(policy_status) = 'ACTIVE'
),
-- Tags that carry a masking policy (tag-based masking), as reported either way round.
sf_gov_masking_tags AS (
  SELECT DISTINCT tag_database, tag_schema, tag_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND tag_name IS NOT NULL
  UNION
  SELECT DISTINCT ref_database_name, ref_schema_name, ref_entity_name, policy_fqn
  FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_entity_domain = 'TAG'
),
sf_gov_tag_masked AS (
  SELECT r.object_database, r.object_schema, r.object_name, r.column_name, r.domain,
         LISTAGG(DISTINCT m.policy_fqn, ', ') AS policies
  FROM sf_gov_tag_refs r
  JOIN sf_gov_masking_tags m
    ON m.tag_database = r.tag_database AND m.tag_schema = r.tag_schema AND m.tag_name = r.tag_name
  GROUP BY 1, 2, 3, 4, 5
),
sf_gov_sensitive_columns AS (
  SELECT s.*,
         COALESCE(d.policies, tc.policies, tt.policies, ts.policies, tdb.policies) AS masking_policies,
         CASE WHEN d.policies IS NOT NULL THEN 'column policy'
              WHEN tc.policies IS NOT NULL THEN 'tag on column'
              WHEN tt.policies IS NOT NULL THEN 'tag on table'
              WHEN ts.policies IS NOT NULL THEN 'tag on schema'
              WHEN tdb.policies IS NOT NULL THEN 'tag on database' END AS masked_via,
         rap.policies AS row_access_policies
  FROM sf_gov_sensitive_tagged s
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, ref_column_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'MASKING_POLICY' AND ref_column_name IS NOT NULL
    GROUP BY 1, 2, 3, 4
  ) d ON d.ref_database_name = s.database_name AND d.ref_schema_name = s.schema_name
     AND d.ref_entity_name = s.table_name AND d.ref_column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tc ON tc.domain = 'COLUMN' AND tc.object_database = s.database_name
     AND tc.object_schema = s.schema_name AND tc.object_name = s.table_name AND tc.column_name = s.column_name
  LEFT JOIN sf_gov_tag_masked tt ON tt.domain = 'TABLE' AND tt.object_database = s.database_name
     AND tt.object_schema = s.schema_name AND tt.object_name = s.table_name
  LEFT JOIN sf_gov_tag_masked ts ON ts.domain = 'SCHEMA' AND ts.object_database = s.database_name
     AND ts.object_name = s.schema_name
  LEFT JOIN sf_gov_tag_masked tdb ON tdb.domain = 'DATABASE' AND tdb.object_name = s.database_name
  LEFT JOIN (
    SELECT ref_database_name, ref_schema_name, ref_entity_name, LISTAGG(DISTINCT policy_fqn, ', ') AS policies
    FROM sf_gov_policy_refs WHERE policy_kind = 'ROW_ACCESS_POLICY'
    GROUP BY 1, 2, 3
  ) rap ON rap.ref_database_name = s.database_name AND rap.ref_schema_name = s.schema_name
     AND rap.ref_entity_name = s.table_name
),
rules (category, privacy_category, confidence, priority, pattern) AS (
  SELECT * FROM VALUES
    ('CREDENTIAL', 'SENSITIVE', 'high', 1, '.*(PASSWORD|PASSWD|PWD|SECRET|API_?KEY|ACCESS_?TOKEN|REFRESH_?TOKEN|PRIVATE_?KEY).*'),
    ('EMAIL', 'IDENTIFIER', 'high', 2, '.*E_?MAIL.*'),
    ('NATIONAL_IDENTIFIER', 'IDENTIFIER', 'high', 3, '(.*_)?(SSN|NINO|AADHAAR|AHV|BSN|NATIONAL_?ID|SOCIAL_?SECURITY.*|PERSONNUMMER|SIN_?(NO|NUM|NUMBER))(_.*)?'),
    ('TAX_IDENTIFIER', 'IDENTIFIER', 'high', 4, '(.*_)?(TAX_?ID|TAX_?NUMBER|TIN|EIN|VAT_?(NO|NUM|NUMBER|ID))(_.*)?'),
    ('PASSPORT', 'IDENTIFIER', 'high', 5, '.*PASSPORT.*'),
    ('DRIVERS_LICENSE', 'IDENTIFIER', 'high', 6, '.*DRIVER_?S?_?LICEN[CS]E.*'),
    ('PAYMENT_CARD', 'IDENTIFIER', 'high', 7, '(.*_)?(CREDIT_?CARD.*|CARD_?(NO|NUM|NUMBER)|CC_?(NO|NUM|NUMBER)|PAN|CVV|CVC)(_.*)?'),
    ('BANK_ACCOUNT', 'IDENTIFIER', 'high', 8, '.*(IBAN|BANK_?ACC(OUNT)?|SORT_?CODE|ROUTING_?(NO|NUM|NUMBER)).*'),
    ('BANK_ACCOUNT', 'IDENTIFIER', 'medium', 9, '(.*_)?ACCOUNT_?(NO|NUM|NUMBER)(_.*)?'),
    ('PHONE_NUMBER', 'IDENTIFIER', 'high', 10, '.*(PHONE|TELEPHONE|MOBILE_?(NO|NUM|NUMBER)|CELL_?(NO|NUM|NUMBER)|FAX_?(NO|NUM|NUMBER)?).*'),
    ('IP_ADDRESS', 'IDENTIFIER', 'high', 11, '(.*_)?(IP|IP_?ADDR(ESS)?|IPV[46])(_.*)?'),
    ('DATE_OF_BIRTH', 'QUASI_IDENTIFIER', 'high', 12, '(.*_)?(DOB|BIRTH_?DATE|DATE_?OF_?BIRTH|BIRTHDAY)(_.*)?'),
    ('YEAR_OF_BIRTH', 'QUASI_IDENTIFIER', 'high', 13, '.*(BIRTH_?YEAR|YEAR_?OF_?BIRTH).*'),
    ('NAME', 'IDENTIFIER', 'medium', 14, '(.*_)?((FIRST|LAST|FULL|MIDDLE|GIVEN|FAMILY|MAIDEN|CUSTOMER|CONTACT|PERSON|EMPLOYEE|PATIENT)_?NAME|SURNAME|FORENAME)(_.*)?'),
    ('STREET_ADDRESS', 'IDENTIFIER', 'medium', 15, '(.*_)?(ADDRESS|ADDR|STREET)(_?(LINE)?_?[0-9])?(_.*)?'),
    ('POSTAL_CODE', 'QUASI_IDENTIFIER', 'medium', 16, '(.*_)?(ZIP|ZIP_?CODE|POSTCODE|POST_?CODE|POSTAL_?CODE)(_.*)?'),
    ('MEDICAL_DATA', 'SENSITIVE', 'medium', 17, '.*(DIAGNOS|MEDICAL|ICD_?10|PRESCRIPTION|ALLERG|MEDICATION).*'),
    ('SALARY', 'SENSITIVE', 'medium', 18, '.*(SALARY|WAGE|PAYROLL|COMPENSATION|INCOME).*'),
    ('GENDER', 'QUASI_IDENTIFIER', 'medium', 19, '(.*_)?(GENDER|SEX)(_.*)?'),
    ('ETHNICITY', 'QUASI_IDENTIFIER', 'medium', 20, '.*(ETHNIC|NATIONALITY).*'),
    ('MARITAL_STATUS', 'QUASI_IDENTIFIER', 'medium', 21, '.*MARITAL.*'),
    ('AGE', 'QUASI_IDENTIFIER', 'low', 22, '(.*_)?AGE(_.*)?'),
    ('CITY', 'QUASI_IDENTIFIER', 'low', 23, '(.*_)?(CITY|TOWN)(_.*)?'),
    ('LAT_LONG', 'QUASI_IDENTIFIER', 'low', 24, '(.*_)?(LAT|LATITUDE|LON|LNG|LONGITUDE|GEO_?LOC(ATION)?)(_.*)?')
),
cols AS (
  SELECT UPPER(c.table_catalog) AS database_name, UPPER(c.table_schema) AS schema_name,
         UPPER(c.table_name) AS table_name, c.table_id, UPPER(c.column_name) AS column_name, c.data_type
  FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
  WHERE c.deleted IS NULL
    AND UPPER(c.table_catalog) <> 'SNOWFLAKE' AND UPPER(c.table_schema) <> 'INFORMATION_SCHEMA'
),
matched AS (
  SELECT c.*, r.category, r.privacy_category, r.confidence, r.priority
  FROM cols c
  JOIN rules r ON REGEXP_LIKE(c.column_name, r.pattern)
   -- device and wallet addresses are not postal addresses
   AND NOT (r.category = 'STREET_ADDRESS' AND REGEXP_LIKE(c.column_name, '.*(MAC|WALLET|BTC|ETH|CONTRACT)_?ADDR.*'))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY c.table_id, c.column_name ORDER BY r.priority) = 1
)
SELECT 0 AS window_days, __ACCOUNT_ID__ AS account_id, m.database_name, m.schema_name, m.table_name,
       m.table_id, m.column_name, m.data_type, m.category AS suggested_category, m.privacy_category,
       m.confidence,
       CASE WHEN m.category = 'CREDENTIAL' THEN 'WARN'
            WHEN m.privacy_category IN ('IDENTIFIER', 'SENSITIVE') AND m.confidence IN ('high', 'medium') THEN 'WARN'
            ELSE 'OK' END AS status
FROM matched m
-- the include lists the columns that already carry a sensitive tag
LEFT JOIN sf_gov_sensitive_columns s
  ON s.database_name = m.database_name AND s.schema_name = m.schema_name AND s.table_name = m.table_name
 AND s.column_name = m.column_name
WHERE s.column_name IS NULL
ORDER BY CASE m.privacy_category WHEN 'IDENTIFIER' THEN 0 WHEN 'SENSITIVE' THEN 1 ELSE 2 END, m.priority,
         m.database_name, m.schema_name, m.table_name, m.column_name
