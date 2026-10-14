-- =====================================================================
-- ZP Imports | Fase 3 (parte 2): rotas de entrega
-- criar_rota: junta pedidos em uma rota com um entregador (pedidos viram "Entrega programada").
-- saiu_rota: marca a saída da rota (pedidos viram "Em rota").
-- desfazer_rota: desfaz a rota antes da saída (pedidos voltam para "Aguardando programação").
-- Só administrador e logística. Rode depois do 08. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

create or replace function public.criar_rota(
  p_data date,
  p_entregador uuid,
  p_pedidos bigint[]
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  quem text;
  rid uuid;
  pid bigint;
  ped public.pedidos;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para criar rotas.'; end if;
  if p_data is null then raise exception 'Informe a data da rota.'; end if;
  if p_pedidos is null or array_length(p_pedidos, 1) is null then raise exception 'Escolha pelo menos um pedido.'; end if;
  if not exists (select 1 from public.entregadores where id = p_entregador and ativo) then
    raise exception 'Escolha um entregador ativo.';
  end if;
  foreach pid in array p_pedidos loop
    select * into ped from public.pedidos where id = pid for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if ped.status in ('entregue','cancelado','em-rota','tentativa','programada') or ped.rota_id is not null then
      raise exception 'O pedido ZP-% não pode entrar em uma nova rota (status atual: %).', lpad(pid::text, 6, '0'), ped.status;
    end if;
  end loop;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  insert into public.rotas (data, entregador_id, pedidos, por)
  values (p_data, p_entregador, p_pedidos, quem) returning id into rid;
  foreach pid in array p_pedidos loop
    perform public.alterar_status_pedido(pid, 'programada', null);
    update public.pedidos set rota_id = rid, entregador_id = p_entregador where id = pid;
  end loop;
  return rid;
end $$;
revoke all on function public.criar_rota(date, uuid, bigint[]) from public, anon;
grant execute on function public.criar_rota(date, uuid, bigint[]) to authenticated;

create or replace function public.saiu_rota(p_rota uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.rotas;
  pid bigint;
  st text;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into r from public.rotas where id = p_rota for update;
  if not found then raise exception 'Rota não encontrada.'; end if;
  if r.saiu_em is not null then raise exception 'Esta rota já saiu.'; end if;
  foreach pid in array r.pedidos loop
    select status into st from public.pedidos where id = pid;
    if st not in ('em-rota','entregue','cancelado') then
      perform public.alterar_status_pedido(pid, 'em-rota', null);
    end if;
  end loop;
  update public.rotas set saiu_em = now() where id = p_rota;
end $$;
revoke all on function public.saiu_rota(uuid) from public, anon;
grant execute on function public.saiu_rota(uuid) to authenticated;

create or replace function public.desfazer_rota(p_rota uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.rotas;
  pid bigint;
  st text;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into r from public.rotas where id = p_rota for update;
  if not found then raise exception 'Rota não encontrada.'; end if;
  if r.saiu_em is not null then raise exception 'A rota já saiu e não pode ser desfeita.'; end if;
  foreach pid in array r.pedidos loop
    select status into st from public.pedidos where id = pid;
    if st = 'programada' then
      perform public.alterar_status_pedido(pid, 'aguardando-programacao', null);
    end if;
    update public.pedidos set rota_id = null, entregador_id = null where id = pid;
  end loop;
  delete from public.rotas where id = p_rota;
end $$;
revoke all on function public.desfazer_rota(uuid) from public, anon;
grant execute on function public.desfazer_rota(uuid) to authenticated;
