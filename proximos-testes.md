# Próximos Testes e Ideias Futuras

Fichas técnicas das ideias pesquisadas durante o projeto com status **"Pesquisada, teste futuro"**, que não puderam ser aplicadas dentro do escopo ou restrições das etapas anteriores.

---

### 1. Cache em Memória com Redis para Relatórios e Buscas
- **Origem / Referência:** [Redis Documentation - Caching Architecture](https://redis.io/docs/latest/develop/use/patterns/caching/)
- **O que ganharia:** Desoneração de até 90% das leituras repetidas em rotas analíticas (`/relatorios/top-produtos` e `/relatorios/vendas-por-dia`), reduzindo o consumo de CPU do container PostgreSQL de 98% para menos de 30% e viabilizando latências sub-milissegundo (< 2 ms).
- **Como testaria:** Adicionar um serviço `redis:7-alpine` ao `docker-compose.yml`, implementar middleware de cache com TTL (ex.: 60 segundos) na API Express para respostas HTTP 200, invalidando ou expirando dados sob demanda. Medir com `scripts/medir.sh 08-cache-redis`.
- **O que precisaria para testar:** Alocar cerca de 64 MB de limite de memória para o container Redis e validar no edital o balanço de custo computacional vs. ganho de vazão.

---

### 2. Paginação Baseada em Cursor (Keyset Pagination) para `/pedidos`
- **Origem / Referência:** [Use The Index, Luke! - Keyset Pagination (Markus Winand)](https://use-the-index-luke.com/no-offset)
- **O que ganharia:** A rota `GET /pedidos?status=&pagina=` sofre com degradação progressiva em páginas profundas (`OFFSET 15000` demora ~60 ms porque o motor do PostgreSQL precisa percorrer e descartar 15.000 tuplas no índice). A paginação por cursor (`WHERE criado_em < $ultimo_criado_em AND id < $ultimo_id`) tem complexidade $O(1)$ constante em qualquer profundidade de página.
- **Como testaria:** Modificar a API para aceitar um cursor criptografado ou tupla `(criado_em, id)` além ou no lugar de `pagina`, mantendo ordenação estrita.
- **O que precisaria para testar:** Mudança na interface da API; violaria o contrato estrito atual que exige parâmetro `pagina` e resposta com `{ pagina, tamanho_pagina, total }`. Exigiria flexibilização do contrato na especificação da rota.

---

### 3. Clustering / Multi-Processamento do Node.js (Cluster Module ou Worker Threads)
- **Origem / Referência:** [Node.js Documentation - Cluster Module](https://nodejs.org/api/cluster.html)
- **O que ganharia:** O container da API atualmente executa em uma única thread no Event Loop. Embora o limite de CPU da API esteja em 0.5 CPU no Compose, permitir que múltiplos processos concorram pelo processamento de serialização JSON (`express` / V8) evitaria que o loop de eventos ficasse bloqueado em momentos de pico de RPS (> 100 req/s).
- **Como testaria:** Utilizar a biblioteca nativa `node:cluster` inicializando 2 workers no container da API, compartilhando a porta 3000.
- **O que precisaria para testar:** Aumentar ligeiramente o limite de CPU da API de 0.5 para 1.0 CPU no `docker-compose.yml`, mensurando a relação custo-benefício de recursos.

---

### 4. Particionamento Declarativo por Range de Data na Tabela `pedidos`
- **Origem / Referência:** [PostgreSQL Documentation - Table Partitioning](https://www.postgresql.org/docs/16/ddl-partitioning.html)
- **O que ganharia:** Particionar a tabela `pedidos` mensalmente ou anualmente (`PARTITION BY RANGE (criado_em)`). Consultas que filtram intervalos de data (como `/relatorios/vendas-por-dia`) realizariam *Partition Pruning*, lendo apenas as partições relevantes em vez de navegar pela árvore B-Tree de meio milhão de registros.
- **Como testaria:** Recriar a tabela em `banco/` como particionada e medir a taxa de I/O e tempo de planejamento sob carga.
- **O que precisaria para testar:** Alteração em `01-estrutura.sql`, o que é estritamente proibido pelas regras da régua do edital (que veta alterações no `01-estrutura.sql` original).
