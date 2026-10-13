# ZP Imports: plano para colocar no ar com Supabase e Netlify

Versão 1 (14/10/2026). Decisão: o sistema vai usar Supabase (banco, login e permissões) e Netlify (hospedagem das telas). Sem WordPress, WooCommerce, Hostinger, PicPay ou Mercado Pago.

## 1. Contas a criar (feitas por você)

1. **Supabase** em [supabase.com](https://supabase.com). Entre com e-mail ou GitHub, clique em **New project** e preencha:
   - Nome: `zp-imports`.
   - Senha do banco: crie uma forte e guarde no seu gerenciador de senhas. **Não me envie.**
   - Região: South America (São Paulo), se aparecer.
2. **Netlify** em [netlify.com](https://www.netlify.com). Basta criar a conta. O primeiro envio do site pode ser arrastando a pasta pelo painel (Add new site, Deploy manually), sem GitHub.
3. **Domínio** em [registro.br](https://registro.br), só quando o sistema estiver aprovado.
4. **WhatsApp real** da loja (para trocar o número de exemplo).
5. **Provedor do link de pagamento** (já definido que será um link único; falta escolher qual).
6. GitHub é opcional: só se quiser guardar o código com histórico.

## 2. O que me enviar depois de criar o projeto no Supabase

Em Project Settings, depois API, copie:
- **Project URL** (algo como `https://xxxx.supabase.co`).
- **anon public key** (chave pública, feita para ficar no site).

**Nunca envie a chave `service_role` nem a senha do banco.** Elas dão acesso total aos dados.

## 3. Fases

| Fase | O que entrega | Precisa de |
|---|---|---|
| 1. Fundação | Banco com as tabelas (pedidos, clientes, produtos, entregadores, rotas, retiradas, configurações), login de clientes e de equipe, perfis admin, logística e separação, regras de acesso | Projeto Supabase |
| 2. Pedido seguro | Checkout que grava o pedido no banco. O servidor calcula preço, desconto, estoque e taxa. O cliente nunca define o próprio preço ou status | Fase 1 |
| 3. Operação | Separação, rotas, entregadores, pagamentos e retiradas gravando no banco, com atualização em tempo real entre as pessoas | Fase 2 |
| 4. Acompanhamento público | Página sem login por link com código secreto, e busca por código e final do telefone, sem expor outros pedidos | Fase 3 |
| 5. Arquivos | PDFs de etiqueta e logomarca guardados com acesso restrito | Fase 3 |
| 6. No ar | Publicação no Netlify, domínio, HTTPS, testes com a equipe, backup e checagem de LGPD | Domínio |

Cada fase termina testada e com um resumo do que mudou, como nas etapas do protótipo.

## 4. Decisões de segurança

- **Preço no servidor:** o valor do pedido é calculado no banco a partir da tabela de produtos. O navegador só envia produtos, quantidades e endereço.
- **Cada perfil só vê o seu:** o cliente enxerga apenas os próprios pedidos. A equipe vê conforme o perfil. Isso é garantido por regras no banco (Row Level Security), não só escondido na tela.
- **Página pública:** não lê a tabela de pedidos diretamente. Usa uma função que devolve um único pedido, só com o código secreto correto.
- **Dados de saúde e de clientes:** o endereço, o telefone e os itens de cada pedido são dados pessoais. Será preciso política de privacidade real, base legal e responsável pelos dados (LGPD).
- **Chaves:** só a chave pública vai no site. A chave `service_role` nunca entra no código das telas.

## 5. Pontos que exigem decisão sua

1. **Login do cliente:** e-mail e senha (como hoje) ou código enviado por WhatsApp. O primeiro é simples e gratuito. O segundo exige a API oficial do WhatsApp.
2. **Plano do Supabase em produção:** projetos gratuitos podem ser pausados por inatividade e têm backup limitado. Para clientes reais, vale o plano pago. Confirme as condições atuais no site deles.
3. **Quem acessa o painel:** lista das pessoas da equipe e o perfil de cada uma.
4. **Retenção de dados:** por quanto tempo guardar pedidos, endereços e etiquetas.
5. **Provedor do link de pagamento** e se ele aceita a categoria de produto.
6. **Repasse ao entregador:** como é calculado e pago.
7. **WhatsApp automático:** continua por botão até você contratar a API oficial.

## 6. O que continua como está

As telas do protótipo, o procedimento operacional (`03-procedimento-operacional-separacao-e-logistica.md`) e os textos. A mudança é por baixo: no lugar do armazenamento do navegador, entra o banco.
