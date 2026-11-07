# Otimização Baseada em Evidências: Elevando o Throughput em 37x e Reduzindo o p95 em 96% sem Custo Adicional

## 1. Resumo

A API da loja virtual apresentava severa degradação de desempenho sob concorrência (20 VUs), sustentando apenas 2,17 req/s com p95 de 28.953 ms devido à saturação total da CPU do banco de dados (98,4%). Através de diagnóstico com `EXPLAIN ANALYZE`, aplicamos sete otimizações cirúrgicas: indexação B-Tree, eliminação de N+1 com agregação JSON, agregação SQL sargable em vendas, Materialized View em top-produtos, busca textual com trigramas GIN, pool de conexões persistente e tuning do PostgreSQL, além de testar uma hipótese de sobredimensionamento de conexões sem ganho. O throughput saltou para 81,66 req/s (+3.663%), o p95 caiu para 1.002 ms (-96,5%) e a mediana geral atingiu 100,7 ms, com uso de memória reduzido e 100% do contrato preservado.

## 2. Contexto e diagnóstico

A aplicação é composta por Node.js 20 (Express) e PostgreSQL 16 em containers Docker com limites de 0.5 CPU / 256MB e 1.0 CPU / 512MB. Na medição inicial da Linha de Base ([resumo da medição](../resultados/20261105-195040-00-linha-de-base/resumo.txt)), o sistema atendeu 195 requisições em 60 segundos (2,17 req/s), com mediana de 1.112,7 ms e p95 de 28.953,4 ms. O container do banco operou saturado a 98,4% de CPU, enquanto a API usou apenas 7,1%.

Diagnósticos via `EXPLAIN (ANALYZE, BUFFERS)` revelaram os seguintes gargalos ([diagnóstico inicial](../diagnostico/01-explain-inicial.txt)):
1. **Varredura Sequencial:** `/clientes?email=` e `/pedidos?status=` executavam `Seq Scan` em 100.000 e 500.000 tuplas por falta de índices.
2. **Consultas N+1:** `/clientes/:id/pedidos` (20% da carga) executava dezenas de `SELECT` síncronos na tabela `produtos` para cada item de pedido.
3. **Agregação na Aplicação:** `/relatorios/vendas-por-dia` transferia dezenas de milhares de linhas brutas para agregação em memória no JavaScript com `new Map()`, usando filtro `criado_em::date` que impedia o uso de índices.
4. **Junção Massiva:** `/relatorios/top-produtos` cruzava 1,5 milhão de itens e 500 mil pedidos com ordenação em disco a cada chamada ([diagnóstico de top-produtos](../diagnostico/06-explain-top-produtos.txt)), levando mais de 2.120 ms.
5. **Busca Textual:** `/produtos/busca` realizava `ILIKE '%termo%'` com varredura completa da tabela.
6. **Conexões Efêmeras:** `api/src/db.js` abria e fechava um `new Client()` a cada query, multiplicando handshakes TCP e custos de autenticação.

**Hipótese de causa:** A ausência de índices relacionais, aliada a consultas N+1, agregações fora do motor e conexões descartáveis, sobrecarregava a CPU do banco e estrangulava a vazão do sistema.

## 3. Estado da arte

### Indexação Relacional e Busca Textual
Índices B-Tree transformam a busca de $O(N)$ para $O(\log N)$, minimizando leituras de páginas em disco (PostgreSQL Global Development Group, 2024a). Para operadores de substring arbitrária (`ILIKE '%...%'`), B-Trees são ineficazes; o estado da arte emprega índices invertidos GIN com decomposição em trigramas (`pg_trgm`), viabilizando buscas textuais em sub-palavras com alta seletividade (PostgreSQL Global Development Group, 2024b).

### Arquitetura de Dados: Resolução de N+1 e Agregação no Motor
O antipadrão N+1 gera múltiplos round-trips sequenciais de rede (Fowler, 2012). Martin Fowler e a documentação do PostgreSQL recomendam consolidar consultas filhas via CTEs e funções nativas (`json_agg`, `json_build_object`), processando o grafo relacional na própria memória do banco (PostgreSQL Global Development Group, 2024c). Paralelamente, agregações como soma e contagem devem ser executadas pelo mecanismo relacional, que possui operadores compilados de hash aggregation superiores à camada de aplicação (Elmasri & Navathe, 2015).

### Materialização de Dados e Pooling de Recursos
Para cálculos caros em dados históricos com baixa frequência de escrita, Visões Materializadas (*Materialized Views*) armazenam o resultado pré-computado, transformando joins de milhões de linhas em leituras diretas indexadas (PostgreSQL Global Development Group, 2024d). Em concorrência elevada, Kleppmann (2017) aponta que a reutilização de conexões por pools persistentes é mandatória para amortizar handshakes de rede e estabilizar a latência de cauda.

## 4. Alternativas consideradas

| Alternativa | Custo | Desempenho | Risco | Esforço |
|---|---|---|---|---|
| **A. Escalonamento Vertical de Hardware** | Alto (aumento contínuo da fatura de nuvem) | Baixo a Médio (gargalos de $O(N)$ saturam qualquer CPU extra) | Baixo | Mínimo |
| **B. Cache Externo Distribuído (Redis)** | Médio (novo serviço e consumo adicional de memória) | Alto (leituras sub-milissegundo em memória) | Médio (invalidação e inconsistência de dados) | Médio |
| **C. Otimização Estrutural de Código e Banco** | Zero (mantém estritamente os limites originais) | Excepcional (elimina causas-raiz de I/O e CPU) | Baixo (contrato 100% validado) | Médio |

## 5. Solução escolhida e por quê

Adotamos a **Alternativa C: Otimização Estrutural de Código e Banco de Dados**.

Escalar hardware (Alternativa A) apenas adiaria a saturação e elevaria custos sem resolver problemas algorítmicos. O uso de Redis (Alternativa B), embora viável, aumentaria o footprint de memória e adicionaria complexidade operacional desnecessária para um volume de 1,5M de registros que o PostgreSQL manipula com eficiência quando bem ajustado.

A solução atacou os gargalos de forma incremental:
1. Índices B-Tree direcionados em chaves de busca (`banco/03-indices.sql`).
2. Eliminação de N+1 com agregação JSON nativa em `/clientes/:id/pedidos` (`api/src/rotas.js`).
3. Agregação SQL com intervalo temporal sargable em `/relatorios/vendas-por-dia`.
4. Pré-cálculo com `MATERIALIZED VIEW` indexada em `/relatorios/top-produtos` (`banco/04-top-produtos.sql`).
5. Índice GIN com extensão `pg_trgm` em `/produtos/busca` (`banco/05-busca-produtos-trgm.sql`).
6. Substituição de conexões efêmeras por pool compartilhado `pg.Pool` (`api/src/db.js`).
7. Ajuste de parâmetros de memória do PostgreSQL (`shared_buffers=128MB`, `work_mem=8MB`, `random_page_cost=1.1`).

## 6. Experimento e resultado

Cada hipótese foi medida 3 vezes sob o protocolo oficial (20 VUs, 60s, semente 42) com `scripts/medir.sh`, sendo avaliada pela mediana das execuções e confirmada pelo verificador de contrato:

| Mudança | Hipótese | p95 antes → depois | req/s antes → depois | CPU/memória | Pastas de resultados | Conclusão |
|---|---|---|---|---|---|---|
| **01-indices** | Índices B-Tree eliminam sequential scans nas rotas frequentes. | 28.953 ms → **8.597 ms** | 2,17 → **8,35** | Banco: 99% / 416MB<br>API: 19% / 41MB | [resultados 01](../resultados/20261105-195616-01-indices) | Confirmada. Throughput quase triplicou e o p95 caiu 70%. |
| **02-elimina-n-mais-1** | Consulta consolidada com `json_agg` elimina round-trips da API. | 8.597 ms → **11.709 ms** (global)<br>*Rota cliente/pedidos: 8.790 ms → 1.036 ms* | 8,35 → **11,07** | Banco: 100% / 408MB<br>API: 16% / 58MB | [resultados 02](../resultados/20261105-200216-02-elimina-n-mais-1) | Confirmada. Latência da rota caiu 90%, aliviando a fila. |
| **03-agregacao-vendas** | Agregar vendas no banco com filtro sargable desonera a API. | 11.709 ms → **7.079 ms** | 11,07 → **12,73** | Banco: 97% / 409MB<br>API: 4,6% / **25MB** | [resultados 03](../resultados/20261105-200838-03-agregacao-vendas) | Confirmada. Memória da API caiu pela metade e a rota acelerou 82%. |
| **04-top-produtos** | Materialized View pré-calculada elimina join de 1,5M de itens. | 7.079 ms → **1.904 ms** | 12,73 → **26,68** | Banco: 100% / 444MB<br>API: 8,5% / 27MB | [resultados 04](../resultados/20261105-201533-04-top-produtos) | Confirmada. Throughput dobrou; rota top-produtos caiu de 21s para 295 ms. |
| **05-busca-trgm** | Índice GIN com `pg_trgm` acelera o ILIKE na busca de produtos. | 1.904 ms → **1.768 ms** | 26,68 → **27,88** | Banco: 98% / 444MB<br>API: 9,3% / 26MB | [resultados 05](../resultados/20261105-202137-05-busca-trgm) | Confirmada. Custo da query caiu de 13 ms para 2 ms; pico de 29,26 req/s. |
| **06-connection-pool** | Pool persistente elimina handshake TCP/auth a cada consulta. | 1.768 ms → **1.591 ms**<br>*Mediana: 492 ms → **95,1 ms*** | 27,88 → **47,55** | Banco: 97% / 408MB<br>API: 6,8% / 26MB | [resultados 06](../resultados/20261105-202704-06-connection-pool) | Confirmada com salto recorde. Mediana despencou 80%, rotas leves em 5-8 ms. |
| **07-pg-tuning** | Ajuste de shared_buffers e custo de página reduz esperas de disco. | 1.591 ms → **1.002 ms** | 47,55 → **81,66** | Banco: 96% / **289MB**<br>API: 9,3% / 26MB | [resultados 07](../resultados/20261105-203230-07-pg-tuning) | Confirmada. Recorde de 81,66 req/s (pico 82,77 req/s) e memória do banco caiu 29%. |
| **08-sem-ganho-pool-grande** | Aumentar pool para max: 60 alivia suposta fila de conexões. | 1.002 ms → **997,9 ms** | 81,66 → **78,20** (-4,2%) | Banco: 98,9% / **481MB**<br>API: 10,2% / 27MB | [resultados 08](../resultados/20261105-205203-08-sem-ganho-pool-grande) | **Aplicada, sem ganho.** Em container restrito a 1 CPU, 60 conexões geraram context-switch e elevaram a memória para 481MB (+66%) com queda de vazão. Revertida para max: 20. |

**Comparativo Consolidado:**
- **Throughput:** subiu de **2,17 req/s** para **81,66 req/s** (**+3.663%**, ou **37,6x mais requisições**).
- **Latência Mediana:** reduziu de **1.112,7 ms** para **100,7 ms** (**redução de 90,9%**).
- **Latência p95:** caiu de **28.953,4 ms** para **1.002,2 ms** (**redução de 96,5%**).
- **Memória do Banco:** diminuiu de **404 MiB** para **289 MiB** (-28,5%).
- **Contrato:** **100% mantido** em todas as medições.

## 7. Limites e testes futuros

1. **Atualização da Materialized View:** A view `mv_top_produtos` é estática. Em cenários de escrita intensa, exige rotina periódica (`REFRESH MATERIALIZED VIEW CONCURRENTLY`) ou tabelas de agregação por triggers.
2. **Paginação Profunda em `/pedidos`:** O uso de `OFFSET 15000` exige escanear e descartar 15 mil tuplas (~60 ms). *Keyset Pagination* (por cursor) resolveria o problema com tempo constante $O(1)$, mas exigiria alterar o contrato da API.
3. **Escalabilidade do Node.js:** Sob concorrências maiores (> 100 VUs), o processo único do Express demandará o módulo nativo `cluster` ou cache distribuído em Redis, conforme detalhado em [próximos testes](../proximos-testes.md).

## 8. Referências

1. Elmasri, R., & Navathe, S. B. (2015). *Fundamentals of Database Systems* (7th ed.). Pearson.
2. Fowler, M. (2012). *Patterns of Enterprise Application Architecture*. Addison-Wesley Professional.
3. Kleppmann, M. (2017). *Designing Data-Intensive Applications*. O'Reilly Media.
4. node-postgres. (2024). *Pool Documentation*. Disponível em: https://node-postgres.com/apis/pool. Acesso em: 05 nov. 2026.
5. PostgreSQL Global Development Group. (2024a). *PostgreSQL 16 Documentation: Chapter 11. Indexes*. Disponível em: https://www.postgresql.org/docs/16/indexes.html. Acesso em: 05 nov. 2026.
6. PostgreSQL Global Development Group. (2024b). *PostgreSQL 16 Documentation: pg_trgm*. Disponível em: https://www.postgresql.org/docs/16/pgtrgm.html. Acesso em: 05 nov. 2026.
7. PostgreSQL Global Development Group. (2024c). *PostgreSQL 16 Documentation: Queries with*. Disponível em: https://www.postgresql.org/docs/16/queries-with.html. Acesso em: 05 nov. 2026.
8. PostgreSQL Global Development Group. (2024d). *PostgreSQL 16 Documentation: Materialized Views*. Disponível em: https://www.postgresql.org/docs/16/rules-materializedviews.html. Acesso em: 05 nov. 2026.
9. PostgreSQL Global Development Group. (2024e). *PostgreSQL 16 Documentation: Chapter 20. Server Configuration*. Disponível em: https://www.postgresql.org/docs/16/runtime-config-resource.html. Acesso em: 05 nov. 2026.
10. Winand, M. (2012). *Use The Index, Luke! - A Guide to Database Performance for Developers*. Disponível em: https://use-the-index-luke.com. Acesso em: 05 nov. 2026.

## 9. Uso de IA

Utilizei o agente Antigravity (com Gemini) para automatizar a execução sequencial das baterias de carga (`medir.sh`), a extração automatizada de planos de execução `EXPLAIN (ANALYZE, BUFFERS)` e a implementação ágil dos scripts SQL e refatorações no Node.js. Todas as hipóteses de diagnóstico, validação contínua da integridade do contrato (42/42 respostas idênticas), conferência manual de cada uma das fontes bibliográficas primárias e a análise crítica dos trade-offs computacionais e de memória foram conduzidas, verificadas e validadas por mim a partir dos logs brutos gerados nos containers.
