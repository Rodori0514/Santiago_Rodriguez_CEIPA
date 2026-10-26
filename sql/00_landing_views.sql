-- name: landing | vistas sobre los Parquet crudos de las tres fuentes
CREATE SCHEMA IF NOT EXISTS landing;

CREATE OR REPLACE VIEW landing.siac_prog      AS SELECT * FROM 'data/landing/siac/siac_prog.parquet';
CREATE OR REPLACE VIEW landing.siac_per_acad  AS SELECT * FROM 'data/landing/siac/siac_per_acad.parquet';
CREATE OR REPLACE VIEW landing.siac_pers      AS SELECT * FROM 'data/landing/siac/siac_pers.parquet';
CREATE OR REPLACE VIEW landing.siac_est       AS SELECT * FROM 'data/landing/siac/siac_est.parquet';
CREATE OR REPLACE VIEW landing.siac_asig      AS SELECT * FROM 'data/landing/siac/siac_asig.parquet';
CREATE OR REPLACE VIEW landing.siac_matr      AS SELECT * FROM 'data/landing/siac/siac_matr.parquet';
CREATE OR REPLACE VIEW landing.siac_calif     AS SELECT * FROM 'data/landing/siac/siac_calif.parquet';
CREATE OR REPLACE VIEW landing.siac_ddl       AS SELECT * FROM 'data/landing/siac/_ddl.parquet';

CREATE OR REPLACE VIEW landing.cp_recaudos    AS SELECT * FROM read_parquet('data/landing/contaplus/recaudos.parquet', union_by_name = true);
CREATE OR REPLACE VIEW landing.cp_cartera     AS SELECT * FROM 'data/landing/contaplus/cartera.parquet';
CREATE OR REPLACE VIEW landing.cp_conceptos   AS SELECT * FROM 'data/landing/contaplus/conceptos.parquet';
CREATE OR REPLACE VIEW landing.cp_archivos    AS SELECT * FROM 'data/landing/contaplus/_archivos.parquet';

CREATE OR REPLACE VIEW landing.crm_programs      AS SELECT * FROM 'data/landing/crm/programs.parquet';
CREATE OR REPLACE VIEW landing.crm_contacts      AS SELECT * FROM 'data/landing/crm/contacts.parquet';
CREATE OR REPLACE VIEW landing.crm_opportunities AS SELECT * FROM 'data/landing/crm/opportunities.parquet';

SELECT table_name, estimated_size FROM duckdb_tables() UNION ALL
SELECT view_name, NULL FROM duckdb_views() WHERE schema_name = 'landing' ORDER BY 1;
