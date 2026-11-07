-- 44: a página do endereço alterado (link da parada) lê a chegada pela mesma rota que o entregador já usa,
-- sem depender de uma coluna específica, e a regra de finalizar (chegada com foto) fica só na função da rota.
-- Rode uma vez no SQL Editor da Supabase, depois do 39 e do 40.

create or replace function public.parada_entregador(p_pedido bigint, p_tok text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  r public.rotas;
  rj jsonb;
  st jsonb;
  sai boolean := false;
begin
  if coalesce(p_tok, '') = '' then return null; end if;
  select * into ped from public.pedidos where id = p_pedido and coalesce(extra->>'ent_tok', '') = p_tok;
  if not found then return null; end if;
  if ped.rota_id is not null then
    select * into r from public.rotas where id = ped.rota_id;
    if found then
      sai := (r.saiu_em is not null);
      begin
        rj := public.rota_entregador(r.id, r.token);
      exception when others then
        rj := null;
      end;
      select e into st from jsonb_array_elements(coalesce(rj->'paradas', '[]'::jsonb)) e
       where (e->>'pedido')::bigint = ped.id limit 1;
    end if;
  end if;
  return jsonb_build_object(
    'pedido', ped.id, 'status', coalesce(st->>'status', ped.status), 'saiu', sai,
    'chegou_em', coalesce(st->>'chegou_em', to_jsonb(ped)->>'chegou_em'),
    'nome', ped.entrega->>'nome', 'fone', ped.entrega->>'fone', 'dest', ped.entrega->'dest',
    'turno', ped.entrega->>'turno');
end $$;

create or replace function public.parada_acao(p_pedido bigint, p_tok text, p_acao text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  r public.rotas;
begin
  if coalesce(p_tok, '') = '' then raise exception 'Link inválido.'; end if;
  select * into ped from public.pedidos where id = p_pedido and coalesce(extra->>'ent_tok', '') = p_tok;
  if not found then raise exception 'Link inválido.'; end if;
  if ped.rota_id is null then raise exception 'Este pedido ainda não está em uma rota.'; end if;
  select * into r from public.rotas where id = ped.rota_id;
  if not found then raise exception 'Rota não encontrada.'; end if;
  perform public.rota_entregador_acao(r.id, r.token, p_pedido, p_acao);
end $$;

revoke all on function public.parada_entregador(bigint, text) from public;
revoke all on function public.parada_acao(bigint, text, text) from public;
grant execute on function public.parada_entregador(bigint, text) to anon, authenticated;
grant execute on function public.parada_acao(bigint, text, text) to anon, authenticated;
