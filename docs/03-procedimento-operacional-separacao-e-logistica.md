# ZP Imports: procedimento operacional (separação, rota, entrega e pagamento)

Versão 2 (14/10/2026). Substitui a versão 1. Os nomes de telas e botões são os do protótipo.

## 1. Como o negócio funciona

1. O cliente faz o pedido no site **sem pagar**.
2. A loja prepara, separa e programa a entrega.
3. O valor já foi combinado com o cliente, com a taxa de entrega informada antes.
4. Quando o pedido **entra em rota**, o cliente recebe uma mensagem no WhatsApp com o valor e o link para acompanhar e pagar.
5. O cliente paga por um **link de pagamento único** (cadastrado na aba Site). A loja registra o recebimento e depois controla as retiradas do cartão.

Não existe gateway no site. Quem confirma o pagamento é uma pessoa da loja, na aba do pedido ou na aba Pagamentos.

## 2. Perfis

| Perfil | Vê | Faz |
|---|---|---|
| Separação | Só a tela Separação | 1º bip e 2º bip |
| Logística | Visão geral, Em aberto, Pedidos, Separação, Logística, Entregadores, Atrasados, Alertas | Gestos da separação, montar rota, enviar rota ao entregador, iniciar rota, enviar o link ao cliente, marcar entregue, tentativa sem sucesso, reagendar, editar entrega |
| Administrador | Tudo, inclusive Pagamentos | Tudo, mais registrar pagamento, retiradas, cancelar, alterar itens, mudar etapa manualmente (com motivo), configurar Site e regras |

Acessos de demonstração: `admin@zpimports.com` / `admin123`, `logistica@zpimports.com` / `logistica123`, `separador@zpimports.com` / `separador123`.

## 3. Etapas do pedido

O cliente vê **5 fases**. Por dentro o sistema guarda 8 etapas.

| Etapa interna | Fase do cliente | Quem aciona | Gesto |
|---|---|---|---|
| Pedido realizado | 1. Pedido realizado | Cliente | Finaliza a compra |
| Pedido confirmado | 2. Em preparação | Separação | **1º bip** (ativa Confirmado e Em preparação) |
| Em preparação | 2. Em preparação | Separação | (mesmo 1º bip) |
| Em separação | 2. Em preparação | Separação | **2º bip** (ativa Em separação e Aguardando programação) |
| Aguardando programação | 2. Em preparação | Separação | (mesmo 2º bip) |
| Entrega programada | 3. Entrega programada | Logística | **Gerar rota** (entra na rota do entregador) |
| Saiu para entrega | 4. Saiu para entrega | Logística | **Iniciar rota** (ou bip na saída) |
| Entregue | 5. Entregue | Logística | **Entregue** |

O pagamento não é uma etapa. Ele tem situação própria: **Pagar por link na rota**, **Link enviado** e **Pagamento recebido**.

Documento físico na bancada: PDF de 2 páginas gerado no momento do pedido. Página 1, etiqueta externa (vai na embalagem, sem produtos nem valores). Página 2, ordem de serviço (cliente, entrega, itens com caixa de conferência, total, observações, código de barras, "Separado por" e "Conferido por"). Se algo mudar no pedido, a etiqueta fica marcada como desatualizada até gerar a versão nova.

## 4. Roteiro da separação (bancada)

1. Abrir a tela **Separação**. A fila mostra os pedidos por data de entrega.
2. Imprimir etiqueta e ordem de serviço (botão no pedido). Se aparecer "Etiqueta desatualizada", gerar a atualizada antes.
3. **1º bip** na ordem de serviço, conferir cliente e itens, clicar em **Iniciar preparação**.
4. Separar os itens, marcar a conferência na ordem de serviço, embalar e colar a etiqueta externa.
5. **2º bip** e clicar em **Separado: deixar para a logística**. Preencher "Separado por" e deixar o volume na área da logística.

Quando algo não bate (item faltando, pedido errado, código não encontrado): não bipar, avisar a logística ou o administrador. Só o administrador volta etapa ou altera itens, sempre com motivo.

## 5. Roteiro da logística

**Montar a rota**
1. Na aba **Logística**, filtrar por cidade, data e turno se quiser.
2. Marcar os pedidos que entram na rota (os que estão "Aguardando programação" ou "Entrega programada").
3. No painel **Montar rota**, escolher o entregador. A lista mostra o nome e o WhatsApp de cada um.
4. Clicar em **Gerar rota**. Os pedidos viram "Entrega programada" e o sistema abre a tela da rota.

**Enviar ao entregador**
5. Conferir o texto da rota (editável) e clicar em **Enviar a rota para o WhatsApp de [nome]**. O WhatsApp abre com a mensagem pronta. O sistema não confirma o envio.
6. A mensagem tem, por pedido: código, cliente, telefone, endereço, referência, data e turno, itens, observações e o aviso "o cliente paga pelo link, não cobrar na entrega".

**Sair para entrega e cobrar**
7. Na saída, clicar em **Iniciar rota**. Todos os pedidos viram "Saiu para entrega", e cada um ganha a mensagem com o link de pagamento.
8. Em cada pedido da rota, clicar em **Enviar link ao cliente**. O WhatsApp do cliente abre com o texto: "Seu pedido já está em rota para entrega... o pagamento deverá ser realizado pelo link abaixo, no valor acordado, incluindo a taxa de entrega informada anteriormente...", com o valor e o endereço da página de acompanhamento. A situação do pagamento passa a "Link enviado".
9. Quando o entregador confirmar, clicar em **Entregue**. Se a entrega falhar, registrar a tentativa sem sucesso com o motivo e reprogramar.

## 6. Pagamento por link

- **Taxa de entrega:** a loja informa ao cliente antes e cadastra no pedido (aba Pagamento do pedido). O **valor combinado** é produtos, menos descontos, mais taxa. Esse valor aparece para o cliente e na mensagem.
- **Link único:** cadastrado em Site, deve começar com https://. Sem ele, o sistema avisa e não deixa enviar a mensagem.
- **Registrar o recebimento:** aba Pagamento do pedido ou aba Pagamentos, botão **Registrar pagamento recebido**. Informa forma (crédito, débito, Pix, outro), parcelas, valor, taxa do provedor e previsão de repasse. O cliente é avisado "Pagamento recebido".
- **Alertas automáticos:** "Em rota sem link de pagamento enviado" e "Entregue sem pagamento recebido".

## 7. Controle do cartão e das retiradas (aba Pagamentos, só administrador)

- **Cartões do alto:** A receber do cliente, Recebido no período, Taxas do provedor, A repassar (líquido), Retirado no período e Recebido no cartão de crédito.
- **Tabela de recebimentos:** pedido, cliente, forma, valor, taxa, líquido, data do pagamento, previsão de repasse e situação (Aguardando o cliente, A repassar, Repassado). Filtros por período, forma e situação.
- **Registrar retirada:** marcar os pagamentos "A repassar", informar a data e clicar em **Registrar retirada**. Eles passam a "Repassado", com o número da retirada. O histórico de retiradas permite desfazer.
- **Estimativas de taxa e prazo** (crédito, débito, Pix) ficam na mesma aba e servem de sugestão. Troque pelos valores reais do seu provedor.

## 8. Entregadores (aba Entregadores)

- **Cadastro:** nome e WhatsApp, com a mesma validação do telefone dos clientes. Dá para editar, desativar e reativar. Entregador inativo não aparece no seletor da rota.
- **Por entregador:** rotas, pedidos entregues, valor total entregue (produtos mais taxas) e taxas de entrega, mais o histórico das rotas.
- **Controle das rotas:** cada rota mostra data, entregador, pedidos (entregues e total), valor da rota, taxas, valor já recebido e situação (Montada, Enviada ao entregador, Em rota, Concluída). Ao abrir uma rota, aparece cada pedido com etapa, pagamento e ações.
- **Valor da rota** soma o valor combinado dos pedidos. O sistema não calcula o repasse ao entregador: se ele recebe pela taxa de entrega ou outro valor, essa regra precisa ser definida.

## 9. Página fixa de acompanhamento e pagamento (sem login)

- O cliente abre o link da mensagem e vê o pedido, as 5 fases, o resumo de entrega, os itens e o **valor combinado**.
- Antes da rota, a página explica que o pagamento será por link, enviado quando o pedido entrar em rota. Quando o pedido está em rota, aparece o botão **Pagar** com o valor.
- Cada pedido tem um link próprio e difícil de adivinhar. Quem não tem o link pode entrar pelo **código do pedido e os 4 últimos números do telefone**.
- O cliente logado vê o mesmo na área Rastrear pedido.

## 10. Painel de gestão

**Visão geral:** duas linhas de seis números, todos clicáveis. Linha 1: Total de pedidos (e quantos ainda sem pagamento), Pedidos pagos, Atrasados, Quase atrasados, Atenção e No prazo. Linha 2: Para separar, Aguardando ou programados, Em rota, Entregues, A receber (valor) e Fechamento do mês (valor recebido). Abaixo, quatro gráficos.

**Aba Em aberto:** todos os pedidos não entregues, do mais atrasado ao mais recente, com bolinha de cor e painel por cidade e turno.

| Cor | Significado | Regra (editável em Regras de entrega) |
|---|---|---|
| Vermelho | Atrasado | Janela de entrega vencida ou pedido parado há mais de 24 h |
| Laranja | Quase atrasado | Entrega em menos de 6 h ou parado há mais de 20 h |
| Amarelo | Atenção | Entrega em menos de 24 h ou parado há mais de 12 h |
| Verde | No prazo | Pedido recente e dentro do prazo |

"Parado" é sem etapa nova, sem alteração e sem aviso ao cliente. Etiqueta, observação interna e WhatsApp aberto não contam.

## 11. Alterar um pedido

Dentro do pedido há abas: Resumo, Entrega, Pagamento, Etiquetas e Histórico. Toda alteração de itens ou de dados de entrega, e todo reagendamento, exige motivo e faz quatro coisas: avisa o cliente no pedido ("Seu pedido foi alterado", como no iFood), registra no histórico, marca a etiqueta como desatualizada e deixa a mensagem de WhatsApp pronta para a loja enviar. Se os itens mudam, o desconto é recalculado.

## 12. Endereço pelo CEP

Ao digitar o CEP, o sistema preenche estado, cidade, bairro e rua (ViaCEP). Cidade e estado ficam travados para manter o padrão, e o endereço é gravado com maiúsculas e minúsculas padronizadas.

## 13. Rota prevista para o cliente

Desde a etapa "Em preparação", o cliente vê a sequência de localidades da rota da região. Se a logística informar saída prevista e minutos por parada, o cliente vê "chegada aproximada por volta das HH:MM", sempre com o aviso de estimativa, que pode ser mais cedo ou mais tarde.

## 14. Pontos a validar na operação real

1. **Mensagem automática no WhatsApp.** Hoje o sistema deixa a mensagem pronta e abre o WhatsApp, e uma pessoa toca em enviar. Envio realmente automático exige a API oficial do WhatsApp (conta Meta verificada, número dedicado, modelo aprovado, custo por mensagem) e só funciona no site real.
2. **Provedor do link de pagamento:** qual será, se aceita a categoria de produto, e se o link aceita crédito, débito e Pix.
3. **Risco de entregar antes de receber.** O sistema alerta "Entregue sem pagamento recebido" e "Em rota sem link enviado". Defina o que fazer quando o cliente não paga (por exemplo, não entregar sem o comprovante).
4. **Repasse ao entregador:** como é calculado e pago.
5. **Hardware:** impressora térmica 100 x 150 mm e leitor de código de barras (não testados).
6. **Taxas e prazos reais** do provedor, para a previsão de repasse.

## 15. Roteiro de teste (15 minutos)

1. Na loja, criar uma conta (telefone válido), fazer um pedido e finalizar. Conferir que não pede pagamento.
2. Como administrador, em Site, cadastrar o link de pagamento (https://...). No pedido, aba Pagamento, informar a taxa de entrega.
3. Como separação, bipar o pedido (digitar ZP-000xxx) e executar os dois bips.
4. Em Entregadores, cadastrar um entregador.
5. Em Logística, marcar o pedido, escolher o entregador e **Gerar rota**. Enviar a rota ao WhatsApp do entregador.
6. **Iniciar rota** e **Enviar link ao cliente**. Abrir a página de acompanhamento do cliente e ver o botão Pagar com o valor.
7. Marcar **Entregue**, ver o alerta "Entregue sem pagamento recebido", registrar o pagamento na aba Pagamentos e registrar uma retirada.
