-- 32: devolução de pedido (vale também para pedido já entregue).
-- Cancela o pedido, devolve o estoque, tira da rota e registra no histórico.

create or replace function public.devolver_pedido(p_pedido bigint, p_motivo text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  ev uuid;
  it jsonb;
  mot text := coalesce(nullif(btrim(coalesce(p_motivo, '')), ''), 'Devolução do pedido');
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status = 'cancelado' then raise exception 'Este pedido já está cancelado.'; end if;

  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();

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
     set status = 'cancelado', reduzido = false, rota_id = null, entregador_id = null,
         extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('devolucao_em', now())
   where id = p_pedido;

  insert into public.pedido_eventos (pedido_id, tipo, de, para, publico, texto, motivo, por)
  values (p_pedido, 'status', ped.status, 'cancelado', true, 'Devolução do pedido registrada. O pedido foi cancelado.', mot, quem)
  returning id into ev;

  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, 'Devolução do pedido', 'A devolução do seu pedido foi registrada.', mot, ev);
end $$;

revoke all on function public.devolver_pedido(bigint, text) from public, anon;
grant execute on function public.devolver_pedido(bigint, text) to authenticated;
