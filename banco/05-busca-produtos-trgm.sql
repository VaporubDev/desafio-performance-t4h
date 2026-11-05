-- 05-busca-produtos-trgm.sql
-- Habilita extensão pg_trgm e cria índice GIN para acelerar a rota /produtos/busca (15% da carga)

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS idx_produtos_nome_trgm ON produtos USING gin (nome gin_trgm_ops);
