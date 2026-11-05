-- 04-top-produtos.sql
-- Materialized view pré-calculada para o relatório analítico de produtos mais vendidos

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_top_produtos AS
SELECT pr.id, pr.nome, pr.categoria,
       sum(i.quantidade)::bigint AS unidades,
       sum(i.quantidade::bigint * i.preco_unitario_centavos::bigint)::bigint AS receita_centavos
  FROM itens_pedido i
  JOIN pedidos p ON p.id = i.pedido_id
  JOIN produtos pr ON pr.id = i.produto_id
 WHERE p.status <> 'cancelado'
 GROUP BY pr.id, pr.nome, pr.categoria
 ORDER BY receita_centavos DESC, pr.id;

CREATE INDEX IF NOT EXISTS idx_mv_top_produtos_rec_id ON mv_top_produtos (receita_centavos DESC, id);
