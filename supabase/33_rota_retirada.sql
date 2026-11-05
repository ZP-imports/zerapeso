-- 33: rota de retirada. O motoboy busca o pedido na casa do cliente e devolve na Base ZP.
-- Fluxo: atribuir (Pagamentos) -> rota -> motoboy finaliza -> Wesley escolhe cobrar taxa ou não
--        -> (taxa pendente de pagamento) -> concluída.

create table if not exists public.retiradas_pedido (
  id uuid primary key default gen_random_uuid(),
  rota_id uuid not null,
  token text not null,
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  entregador_id uuid not null references public.entregadores(id),
  ordem int not null default 0,
  status text not null default 'rota' check (status in ('rota','retirado','taxa','concluida')),
  taxa numeric(10,2) not null default 0,
  chegou_em timestamptz,
  retirado_em timestamptz,
  taxa_paga_em timestamptz,
  concluida_em timestamptz,
  enviada_em timestamptz,
  criado_em timestamptz not null default now(),
  por text
);
create index if not exists retiradas_pedido_rota_idx on public.retiradas_pedido (rota_id);
create unique index if not exists retiradas_pedido_ativa_uk on public.retiradas_pedido (pedido_id) where status in ('rota','retirado','taxa');

alter table public.retiradas_pedido enable row level security;
drop policy if exists retiradas_pedido_ler on public.retiradas_pedido;
create policy retiradas_pedido_ler on public.retiradas_pedido for select to authenticated using (public.eh_gestao());
drop policy if exists retiradas_pedido_editar on public.retiradas_pedido;
create policy retiradas_pedido_editar on public.retiradas_pedido for update to authenticated using (public.eh_gestao()) with check (public.eh_gestao());

-- devolve o pedido à loja: cancela, devolve o estoque e tira de qualquer rota de entrega
create or replace function public._retirada_devolve(p_pedido bigint, p_quem text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  it jsonb;
  ev uuid;
begin
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found or ped.status = 'cancelado' then return; end if;
  if ped.reduzido then
    for it in select * from jsonb_array_elements(ped.itens) loop
      update public.produtos
         set estoque = estoque + (it->>'qty')::int * coalesce((it->>'unidades')::int, 1), atualizado_em = now()
       where id = (it->>'id')::int;
    end loop;
  end if;
  if ped.rota_id is not null then
    update public.rotas set pedidos = array_remove(pedidos, p_pedido) where id = ped.rota_id;
  end if;
  update public.pedidos
     set status = 'cancelado', reduzido = false, rota_id = null, entregador_id = null
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, de, para, publico, texto, motivo, por)
  values (p_pedido, 'status', ped.status, 'cancelado', true, 'O pedido foi retirado e devolvido à loja.', 'Retirada do pedido', p_quem)
  returning id into ev;
  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, 'Pedido devolvido', 'O seu pedido foi retirado e devolvido à loja.', 'Retirada do pedido', ev);
end $$;
revoke all on function public._retirada_devolve(bigint, text) from public, anon, authenticated;

-- Wesley atribui um pedido a um entregador. Se o entregador já tem uma rota de retirada aberta, entra nela.
create or replace function public.atribuir_retirada(p_pedido bigint, p_entregador uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  rid uuid;
  tk text;
  ord int;
  novo uuid;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status = 'cancelado' then raise exception 'Este pedido está cancelado.'; end if;
  if exists (select 1 from public.retiradas_pedido where pedido_id = p_pedido and status in ('rota','retirado','taxa')) then
    raise exception 'Este pedido já está em uma rota de retirada.';
  end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  select rota_id, token into rid, tk from public.retiradas_pedido
   where entregador_id = p_entregador and status = 'rota' order by criado_em desc limit 1;
  if rid is null then
    rid := gen_random_uuid();
    tk := md5(random()::text || clock_timestamp()::text || p_pedido::text);
  end if;
  select coalesce(max(ordem), 0) + 1 into ord from public.retiradas_pedido where rota_id = rid;
  insert into public.retiradas_pedido (rota_id, token, pedido_id, entregador_id, ordem, por)
  values (rid, tk, p_pedido, p_entregador, ord, quem) returning id into novo;
  update public.pedidos set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('ret', 'rota', 'ret_id', novo) where id = p_pedido;
  return jsonb_build_object('id', novo, 'rota', rid, 'token', tk);
end $$;

-- tira o pedido da rota (só antes de o motoboy finalizar): volta para Pagamentos
create or replace function public.cancelar_retirada(p_retirada uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.retiradas_pedido;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into r from public.retiradas_pedido where id = p_retirada for update;
  if not found then raise exception 'Retirada não encontrada.'; end if;
  if r.status <> 'rota' then raise exception 'Esta retirada já foi finalizada pelo motoboy.'; end if;
  delete from public.retiradas_pedido where id = p_retirada;
  update public.pedidos set extra = (coalesce(extra, '{}'::jsonb) - 'ret') - 'ret_id' where id = r.pedido_id;
end $$;

-- ordem das paradas (vem da otimização por proximidade)
create or replace function public.retirada_ordem(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare i int;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  for i in 1 .. coalesce(array_length(p_ids, 1), 0) loop
    update public.retiradas_pedido set ordem = i where id = p_ids[i] and status = 'rota';
  end loop;
end $$;

-- página do motoboy (link com token, sem login)
create or replace function public.retirada_entregador(p_rota uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  if not exists (select 1 from public.retiradas_pedido where rota_id = p_rota and token = p_token) then return null; end if;
  select jsonb_build_object(
           'rota', p_rota,
           'paradas', coalesce(jsonb_agg(jsonb_build_object(
              'id', r.id, 'pedido', r.pedido_id, 'status', r.status, 'chegou_em', r.chegou_em,
              'nome', p.entrega->>'nome', 'fone', p.entrega->>'fone', 'dest', p.entrega->'dest'
           ) order by r.ordem, r.criado_em), '[]'::jsonb))
    into res
    from public.retiradas_pedido r join public.pedidos p on p.id = r.pedido_id
   where r.rota_id = p_rota and r.token = p_token;
  return res;
end $$;

create or replace function public.retirada_acao(p_rota uuid, p_token text, p_retirada uuid, p_acao text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.retiradas_pedido;
begin
  select * into r from public.retiradas_pedido where id = p_retirada and rota_id = p_rota and token = p_token for update;
  if not found then raise exception 'Retirada não encontrada.'; end if;
  if p_acao = 'cheguei' then
    if r.status = 'rota' then update public.retiradas_pedido set chegou_em = coalesce(chegou_em, now()) where id = r.id; end if;
  elsif p_acao = 'finalizar' then
    if r.status <> 'rota' then raise exception 'Esta retirada já foi finalizada.'; end if;
    update public.retiradas_pedido set status = 'retirado', retirado_em = now(), chegou_em = coalesce(chegou_em, now()) where id = r.id;
    perform public._retirada_devolve(r.pedido_id, 'Entregador');
    update public.pedidos set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('ret', 'retirado') where id = r.pedido_id;
  else
    raise exception 'Ação inválida.';
  end if;
end $$;

-- Wesley decide: sem taxa conclui; com taxa fica pendente de pagamento
create or replace function public.concluir_retirada(p_retirada uuid, p_taxa numeric) returns void
language plpgsql security definer set search_path = public as $$
declare r public.retiradas_pedido; t numeric := coalesce(p_taxa, 0);
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into r from public.retiradas_pedido where id = p_retirada for update;
  if not found then raise exception 'Retirada não encontrada.'; end if;
  if r.status <> 'retirado' then raise exception 'O motoboy ainda não finalizou esta retirada.'; end if;
  if t > 0 then
    update public.retiradas_pedido set status = 'taxa', taxa = t where id = r.id;
    update public.pedidos set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('ret', 'taxa') where id = r.pedido_id;
  else
    update public.retiradas_pedido set status = 'concluida', taxa = 0, concluida_em = now() where id = r.id;
    update public.pedidos set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('ret', 'ok') where id = r.pedido_id;
  end if;
end $$;

create or replace function public.taxa_retirada_paga(p_retirada uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.retiradas_pedido;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into r from public.retiradas_pedido where id = p_retirada for update;
  if not found then raise exception 'Retirada não encontrada.'; end if;
  if r.status <> 'taxa' then raise exception 'Esta retirada não tem taxa pendente.'; end if;
  update public.retiradas_pedido set status = 'concluida', taxa_paga_em = now(), concluida_em = now() where id = r.id;
  update public.pedidos set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('ret', 'ok') where id = r.pedido_id;
end $$;

revoke all on function public.atribuir_retirada(bigint, uuid) from public, anon;
revoke all on function public.cancelar_retirada(uuid) from public, anon;
revoke all on function public.retirada_ordem(uuid[]) from public, anon;
revoke all on function public.concluir_retirada(uuid, numeric) from public, anon;
revoke all on function public.taxa_retirada_paga(uuid) from public, anon;
grant execute on function public.atribuir_retirada(bigint, uuid) to authenticated;
grant execute on function public.cancelar_retirada(uuid) to authenticated;
grant execute on function public.retirada_ordem(uuid[]) to authenticated;
grant execute on function public.concluir_retirada(uuid, numeric) to authenticated;
grant execute on function public.taxa_retirada_paga(uuid) to authenticated;

revoke all on function public.retirada_entregador(uuid, text) from public;
revoke all on function public.retirada_acao(uuid, text, uuid, text) from public;
grant execute on function public.retirada_entregador(uuid, text) to anon, authenticated;
grant execute on function public.retirada_acao(uuid, text, uuid, text) to anon, authenticated;
