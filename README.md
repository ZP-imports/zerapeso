# ZP Imports

E-commerce completo da ZP Imports — loja para clientes e painel de operação (pedidos, separação, rotas, entregadores e pagamentos por link).

## Arquivos

- `index.html` — loja do cliente: catálogo, carrinho, checkout, rastreamento de pedidos e cadastro
- `admin.html` — painel de operação: gestão de pedidos, produtos, entregadores, rotas e configurações
- `supabase/` — migrations e configuração do banco de dados
- `docs/` — procedimento operacional e plano de implantação

## Stack

- Front-end: HTML/CSS/JS puro (SPA com hash routing, sem dependências externas)
- Banco de dados: Supabase (Postgres + Realtime)
- Hospedagem: Netlify

## Observações

Este repositório é privado. Não coloque chaves secretas aqui — apenas a chave pública do Supabase pode ir no código.
