-- Standard credits per hour by warehouse size, keyed by UPPER(REPLACE(size, '-', '')) so sizes from
-- SHOW WAREHOUSES and QUERY_HISTORY both match; smaller_size is the one-step-down target for resizing.
sf_wh_size_rate AS (
  SELECT column1 AS size_key, column2 AS size_rank, column3 AS credits_per_hour,
         column4 AS smaller_size, column5 AS larger_size
  FROM VALUES
    ('XSMALL', 1, 1, 'none', 'Small'), ('SMALL', 2, 2, 'X-Small', 'Medium'),
    ('MEDIUM', 3, 4, 'Small', 'Large'), ('LARGE', 4, 8, 'Medium', 'X-Large'),
    ('XLARGE', 5, 16, 'Large', '2X-Large'), ('2XLARGE', 6, 32, 'X-Large', '3X-Large'),
    ('XXLARGE', 6, 32, 'X-Large', '3X-Large'), ('X2LARGE', 6, 32, 'X-Large', '3X-Large'),
    ('3XLARGE', 7, 64, '2X-Large', '4X-Large'), ('XXXLARGE', 7, 64, '2X-Large', '4X-Large'),
    ('X3LARGE', 7, 64, '2X-Large', '4X-Large'), ('4XLARGE', 8, 128, '3X-Large', '5X-Large'),
    ('X4LARGE', 8, 128, '3X-Large', '5X-Large'), ('5XLARGE', 9, 256, '4X-Large', '6X-Large'),
    ('X5LARGE', 9, 256, '4X-Large', '6X-Large'), ('6XLARGE', 10, 512, '5X-Large', 'none'),
    ('X6LARGE', 10, 512, '5X-Large', 'none')
)
