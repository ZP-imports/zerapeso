-- =====================================================================
-- ZP Imports | Fase 3 (parte 1): operação dos pedidos pelo painel
-- 1) alterar_status_pedido: muda o status, grava o histórico, avisa o cliente
--    e, no cancelamento, devolve o estoque.
-- 2) registrar_pagamento: marca o pedido como pago (ou volta para pendente).
-- 3) atualizar_pedido_admin: ajusta data/turno desejados e a observação interna.
-- Só administrador e logística conseguem usar. Rode depois do 01 ao 07.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run. Pode rodar mais de uma vez.
-- =====================================================================

create or replace function public.alterar_status_pedido(
  p_pedido bigint,
  p_status text,
  p_motivo text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  titulo text;
  texto text;
  ev uuid;
  it jsonb;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if p_status not in ('realizado','confirmado','preparacao','separacao','aguardando-programacao','programada','em-rota','entregue','tentativa','cancelado') then
    raise exception 'Status inválido.';
  end if;
  if ped.status in ('entregue','cancelado') then raise exception 'Este pedido já foi encerrado e não pode mais mudar de status.'; end if;
  if ped.status = p_status then raise exception 'O pedido já está neste status.'; end if;
  if p_status = 'cancelado' and coalesce(btrim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento.'; end if;

  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

  -- cancelamento devolve o estoque (em unidades) uma única vez
  if p_status = 'cancelado' and ped.reduzido then
    for it in select * from jsonb_array_elements(ped.itens) loop
      update public.produtos
         set estoque = estoque + (it->>'qty')::int * coalesce((it->>'unidades')::int, 1), atualizado_em = now()
       where id = (it->>'id')::int;
    end loop;
  end if;

  update public.pedidos
     set status = p_status,
         reduzido = case when p_status = 'cancelado' then false else reduzido end
   where id = p_pedido;

  titulo := case p_status
    when 'realizado' then 'Pedido recebido'
    when 'confirmado' then 'Pedido confirmado'
    when 'preparacao' then 'Pedido em preparação'
    when 'separacao' then 'Pedido em separação'
    when 'aguardando-programacao' then 'Aguardando programação da entrega'
    when 'programada' then 'Entrega programada'
    when 'em-rota' then 'Seu pedido saiu para entrega'
    when 'entregue' then 'Pedido entregue'
    when 'tentativa' then 'Tentativa de entrega'
    when 'cancelado' then 'Pedido cancelado'
  end;
  texto := case p_status
    when 'confirmado' then 'Confirmamos o seu pedido.'
    when 'preparacao' then 'Estamos preparando o seu pedido.'
    when 'separacao' then 'Estamos separando os itens do seu pedido.'
    when 'aguardando-programacao' then 'Estamos definindo a data e o horário da entrega.'
    when 'programada' then 'A entrega do seu pedido foi programada.'
    when 'em-rota' then 'O seu pedido saiu para entrega.'
    when 'entregue' then 'O seu pedido foi entregue. Obrigado pela compra.'
    when 'tentativa' then 'Tentamos entregar o seu pedido e não foi possível. Nossa equipe vai entrar em contato.'
    when 'cancelado' then 'O seu pedido foi cancelado.'
    else 'O status do seu pedido foi atualizado.'
  end;

  insert into public.pedido_eventos (pedido_id, tipo, de, para, publico, texto, motivo, por)
  values (p_pedido, 'status', ped.status, p_status, true, texto, nullif(btrim(coalesce(p_motivo, '')), ''), quem)
  returning id into ev;

  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, titulo, texto, nullif(btrim(coalesce(p_motivo, '')), ''), ev);
end $$;
revoke all on function public.alterar_status_pedido(bigint, text, text) from public, anon;
grant execute on function public.alterar_status_pedido(bigint, text, text) to authenticated;

create or replace function public.registrar_pagamento(
  p_pedido bigint,
  p_pago boolean
) returns void
language plpgsql security definer set search_path = public as $$
declare
  quem text;
  ped public.pedidos;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para registrar pagamento.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status = 'cancelado' then raise exception 'Pedido cancelado não recebe pagamento.'; end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  update public.pedidos
     set pagamento = case when p_pago
           then pagamento || jsonb_build_object('status', 'pago', 'pagoEm', now())
           else (pagamento - 'pagoEm') || jsonb_build_object('status', 'pendente') end
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (p_pedido, 'pagamento', p_pago, case when p_pago then 'Pagamento recebido.' else 'Pagamento voltou para pendente.' end, quem);
end $$;
revoke all on function public.registrar_pagamento(bigint, boolean) from public, anon;
grant execute on function public.registrar_pagamento(bigint, boolean) to authenticated;

create or replace function public.atualizar_pedido_admin(
  p_pedido bigint,
  p_data date,
  p_turno text,
  p_obs_interna text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  quem text;
  ped public.pedidos;
  mudou boolean;
  ev uuid;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if p_turno not in ('manha','tarde','noite') then raise exception 'Turno inválido.'; end if;
  if p_data is null then raise exception 'Informe a data.'; end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  mudou := (ped.entrega->>'data') is distinct from p_data::text or (ped.entrega->>'turno') is distinct from p_turno;
  update public.pedidos
     set entrega = entrega || jsonb_build_object('data', p_data::text, 'turno', p_turno),
         obs_interna = nullif(btrim(coalesce(p_obs_interna, '')), '')
   where id = p_pedido;
  if mudou then
    insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
    values (p_pedido, 'entrega', true, 'A data ou o horário da entrega foi ajustado pela loja.', quem)
    returning id into ev;
    insert into public.pedido_avisos (pedido_id, titulo, texto, evento_id)
    values (p_pedido, 'Entrega reagendada', 'A data ou o horário da entrega do seu pedido foi ajustado pela loja. Confira em Rastrear pedido.', ev);
  end if;
end $$;
revoke all on function public.atualizar_pedido_admin(bigint, date, text, text) from public, anon;
grant execute on function public.atualizar_pedido_admin(bigint, date, text, text) to authenticated;

-- link de pagamento fixo (usado só pelo painel: o vendedor envia pelo WhatsApp)
insert into public.configuracao (chave, valor, publica)
values ('pagamento', '{"linkPag":"https://link.mercadopago.com.br/zplink"}'::jsonb, false)
on conflict (chave) do update
  set valor = jsonb_set(public.configuracao.valor, '{linkPag}', '"https://link.mercadopago.com.br/zplink"'::jsonb)
  where coalesce(public.configuracao.valor->>'linkPag', '') = '';
