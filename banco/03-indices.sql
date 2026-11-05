-- 03-indices.sql
-- Índices essenciais para eliminar Sequential Scans nas rotas mais frequentes

-- 1. Rota /clientes?email= (15% da carga)
-- Query: WHERE lower(email) = lower($1) ORDER BY id
CREATE INDEX IF NOT EXISTS idx_clientes_lower_email ON clientes (lower(email));

-- 2. Rota /clientes/:id/pedidos (20% da carga)
-- Query pedidos: WHERE cliente_id = $1 ORDER BY criado_em DESC, id DESC
CREATE INDEX IF NOT EXISTS idx_pedidos_cliente_criado_id ON pedidos (cliente_id, criado_em DESC, id DESC);

-- Query itens_pedido: WHERE pedido_id = $1 ORDER BY id
CREATE INDEX IF NOT EXISTS idx_itens_pedido_pedido_id_id ON itens_pedido (pedido_id, id);

-- 3. Rota /pedidos?status=&pagina= (15% da carga)
-- Query: WHERE status = $1 ORDER BY criado_em DESC, id DESC
CREATE INDEX IF NOT EXISTS idx_pedidos_status_criado_id ON pedidos (status, criado_em DESC, id DESC);
