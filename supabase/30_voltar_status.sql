-- 30_voltar_status.sql
-- Corrigir clique errado: volta o pedido para uma etapa anterior, sem avisar o cliente.
-- Se o pedido estava numa rota e volta para antes de "Enviado ao entregador", ele sai da rota
-- (a rota que ficar vazia é apagada). Não mexe em pagamento (use "Voltar para pendente").
-- Só cria uma função nova. Rode uma vez no SQL Editor da Supabase.

create or replace function public.voltar_status_pedido(
  p_pedido bigint,
  p_status text,
  p_motivo text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  ordem text[] := array['realizado','confirmado','preparacao','separacao','aguardando-programacao','programada','em-rota','tentativa','entregue'];
  i_atual int;
  i_novo int;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status = 'cancelado' then raise exception 'Pedido cancelado não pode voltar de etapa.'; end if;
  if p_status not in ('realizado','confirmado','separacao','aguardando-programacao','programada','em-rota') then
    raise exception 'Etapa inválida.';
  end if;
  i_atual := array_position(ordem, ped.status);
  i_novo := array_position(ordem, p_status);
  if i_atual is null or i_novo is null or i_novo >= i_atual then
    raise exception 'Escolha uma etapa anterior à atual.';
  end if;

  -- voltando para antes de "Enviado ao entregador": sai da rota
  if i_novo < array_position(ordem, 'programada') and ped.rota_id is not null then
    update public.rotas set pedidos = array_remove(pedidos, p_pedido) where id = ped.rota_id;
    delete from public.rotas where id = ped.rota_id and coalesce(array_length(pedidos, 1), 0) = 0;
    update public.pedidos set rota_id = null, entregador_id = null where id = p_pedido;
  end if;

  update public.pedidos set status = p_status where id = p_pedido;

  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  insert into public.pedido_eventos (pedido_id, tipo, de, para, publico, texto, motivo, por)
  values (p_pedido, 'status', ped.status, p_status, false,
          'Etapa corrigida pela equipe: voltou de "' || ped.status || '" para "' || p_status || '" (cliente não avisado).',
          nullif(btrim(coalesce(p_motivo, '')), ''), coalesce(quem, 'Equipe'));
end $$;

revoke all on function public.voltar_status_pedido(bigint, text, text) from public, anon;
grant execute on function public.voltar_status_pedido(bigint, text, text) to authenticated;
