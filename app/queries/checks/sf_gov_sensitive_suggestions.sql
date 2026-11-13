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
-- read_this: one row = one live untagged column whose name looks like a semantic category or a credential.
--   The patterns follow Snowflake's semantic categories (EMAIL, PHONE_NUMBER, NATIONAL_IDENTIFIER ...) plus
--   CREDENTIAL (not a Snowflake category: passwords, tokens, secrets). suggested_category and privacy_category are what
--   SNOWFLAKE.CORE.SEMANTIC_CATEGORY and PRIVACY_CATEGORY would most likely say; confidence is high when
--   the name is unambiguous (EMAIL, SSN, IBAN), medium when it often is (ADDRESS, ACCOUNT_NUMBER), low for
--   quasi-identifiers that are often harmless (CITY, AGE). Snowflake classification, which reads the data,
--   confirms it.
-- healthy: status = OK when nothing that looks like an identifier is untagged.
-- investigate_if: WARN for an untagged column that looks like an IDENTIFIER or SENSITIVE with high or
--   medium confidence or a credential; OK for the rest, listed as a suggestion.
-- actions: 1) run Snowflake classification on the tables listed (CALL SYSTEM$CLASSIFY with auto_tag, or
--   a classification profile on the database) so the system tags are set from the data (serverless
--   credits, spend); 2) put masking policies on the classification tags (config)
-- next: sf_gov_classification_coverage
-- caveats: names lie both ways: a column called C7 holding emails is missed, and NAME_ID is flagged.
--   Tags seen are direct tags on the column only; the role sees only the columns of objects it can
--   access. Classification results the account already has are in sf_gov_classification_coverage.
WITH __INCLUDE_sf_gov_sensitive_columns__,
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
