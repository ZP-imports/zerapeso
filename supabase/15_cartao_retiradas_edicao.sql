-- =====================================================================
-- ZP Imports | Fase 3 (parte 3): recebimentos, retiradas e edição do pedido
-- 1) registrar_recebimento / desfazer_recebimento: registra o pagamento recebido
--    (forma, parcelas, valor, taxa, líquido e previsão de repasse).
-- 2) criar_retirada / desfazer_retirada: agrupa recebimentos retirados (só administrador).
-- 3) editar_itens_pedido / editar_endereco_pedido: ajusta quantidades e endereço,
--    mexe no estoque, avisa o cliente e deixa a etiqueta como desatualizada.
-- Rode depois do 01 ao 14. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Recebimento
-- ---------------------------------------------------------------------
create or replace function public.registrar_recebimento(
  p_pedido bigint,
  p_forma text,
  p_parcelas int,
  p_bruto numeric,
  p_taxa_pct numeric,
  p_prev date
) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  taxa numeric;
  liq numeric;
  ev uuid;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para registrar pagamento.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status = 'cancelado' then raise exception 'Pedido cancelado não recebe pagamento.'; end if;
  if coalesce(ped.pagamento->>'status', '') = 'pago' then raise exception 'O pagamento deste pedido já foi registrado.'; end if;
  if p_forma not in ('pix','credito','debito','outro') then raise exception 'Forma de pagamento inválida.'; end if;
  if p_bruto is null or p_bruto <= 0 then raise exception 'Informe o valor recebido.'; end if;
  if p_taxa_pct is null or p_taxa_pct < 0 or p_taxa_pct > 30 then raise exception 'A taxa deve ficar entre 0%% e 30%%.'; end if;
  if p_prev is null then raise exception 'Informe a previsão de repasse.'; end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  taxa := round(p_bruto * p_taxa_pct / 100, 2);
  liq := round(p_bruto - taxa, 2);
  update public.pedidos
     set pagamento = pagamento || jsonb_build_object(
       'status', 'pago', 'forma', p_forma,
       'parcelas', case when p_forma = 'credito' then greatest(1, least(12, coalesce(p_parcelas, 1))) else 1 end,
       'bruto', p_bruto, 'taxaPct', p_taxa_pct, 'taxaValor', taxa, 'liquido', liq,
       'pagoEm', now(), 'prevRepasse', p_prev::text, 'repassado', false)
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (p_pedido, 'pagamento', true, 'Pagamento recebido.', quem) returning id into ev;
  insert into public.pedido_avisos (pedido_id, titulo, texto, evento_id)
  values (p_pedido, 'Pagamento recebido', 'Recebemos o pagamento do seu pedido ZP-' || lpad(p_pedido::text, 6, '0') || '. Obrigado!', ev);
end $$;
revoke all on function public.registrar_recebimento(bigint, text, int, numeric, numeric, date) from public, anon;
grant execute on function public.registrar_recebimento(bigint, text, int, numeric, numeric, date) to authenticated;

create or replace function public.desfazer_recebimento(p_pedido bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão.'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if coalesce(ped.pagamento->>'status', '') <> 'pago' then raise exception 'Este pedido não está como pago.'; end if;
  if coalesce((ped.pagamento->>'repassado')::boolean, false) then
    raise exception 'Este pagamento já está em uma retirada. Desfaça a retirada primeiro.';
  end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  update public.pedidos
     set pagamento = (pagamento - 'forma' - 'parcelas' - 'bruto' - 'taxaPct' - 'taxaValor' - 'liquido' - 'pagoEm' - 'prevRepasse' - 'repassado' - 'retiradaId')
                     || jsonb_build_object('status', 'pendente')
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
  values (p_pedido, 'pagamento', false, 'Registro de pagamento desfeito.', quem);
end $$;
revoke all on function public.desfazer_recebimento(bigint) from public, anon;
grant execute on function public.desfazer_recebimento(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Retiradas (só administrador)
-- ---------------------------------------------------------------------
create or replace function public.criar_retirada(p_data date, p_pedidos bigint[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  quem text;
  pid bigint;
  ped public.pedidos;
  total numeric := 0;
  rid uuid;
begin
  if not public.eh_admin() then raise exception 'Apenas administradores registram retiradas.'; end if;
  if p_data is null then raise exception 'Informe a data da retirada.'; end if;
  if p_pedidos is null or array_length(p_pedidos, 1) is null then raise exception 'Marque os pagamentos da retirada.'; end if;
  foreach pid in array p_pedidos loop
    select * into ped from public.pedidos where id = pid for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if coalesce(ped.pagamento->>'status', '') <> 'pago' or ped.pagamento->>'liquido' is null then
      raise exception 'O pedido ZP-% não tem pagamento registrado.', lpad(pid::text, 6, '0');
    end if;
    if coalesce((ped.pagamento->>'repassado')::boolean, false) then
      raise exception 'O pedido ZP-% já está em outra retirada.', lpad(pid::text, 6, '0');
    end if;
    total := total + (ped.pagamento->>'liquido')::numeric;
  end loop;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  insert into public.retiradas (data, total, pedidos, por) values (p_data, round(total, 2), p_pedidos, quem) returning id into rid;
  foreach pid in array p_pedidos loop
    update public.pedidos set pagamento = pagamento || jsonb_build_object('repassado', true, 'retiradaId', rid::text) where id = pid;
    insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
    values (pid, 'pagamento', false, 'Incluído na retirada de ' || to_char(p_data, 'DD/MM/YYYY') || '.', quem);
  end loop;
  return rid;
end $$;
revoke all on function public.criar_retirada(date, bigint[]) from public, anon;
grant execute on function public.criar_retirada(date, bigint[]) to authenticated;

create or replace function public.desfazer_retirada(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  r public.retiradas;
  pid bigint;
  quem text;
begin
  if not public.eh_admin() then raise exception 'Apenas administradores desfazem retiradas.'; end if;
  select * into r from public.retiradas where id = p_id for update;
  if not found then raise exception 'Retirada não encontrada.'; end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  foreach pid in array r.pedidos loop
    update public.pedidos set pagamento = (pagamento - 'retiradaId') || jsonb_build_object('repassado', false) where id = pid;
    insert into public.pedido_eventos (pedido_id, tipo, publico, texto, por)
    values (pid, 'pagamento', false, 'Retirada de ' || to_char(r.data, 'DD/MM/YYYY') || ' desfeita.', quem);
  end loop;
  delete from public.retiradas where id = p_id;
end $$;
revoke all on function public.desfazer_retirada(uuid) from public, anon;
grant execute on function public.desfazer_retirada(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Edição de itens e endereço
-- ---------------------------------------------------------------------
create or replace function public.editar_itens_pedido(p_pedido bigint, p_qtds jsonb, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  it jsonb;
  novos jsonb := '[]'::jsonb;
  k int := 0;
  nq int;
  oq int;
  delta int;
  prod public.produtos;
  subtotal numeric := 0;
  desc_novo jsonb;
  pct numeric;
  sp boolean;
  ev uuid;
  mot text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  if mot is null then raise exception 'Informe o motivo da alteração (o cliente será avisado).'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status in ('em-rota','entregue','tentativa','cancelado') then
    raise exception 'Este pedido não pode mais ter os itens alterados (status: %).', ped.status;
  end if;
  if p_qtds is null or jsonb_typeof(p_qtds) <> 'array' or jsonb_array_length(p_qtds) <> jsonb_array_length(ped.itens) then
    raise exception 'Quantidades inválidas.';
  end if;
  for it in select * from jsonb_array_elements(ped.itens) loop
    begin
      nq := (p_qtds->>k)::int;
    exception when others then
      raise exception 'Quantidade inválida.';
    end;
    if nq is null or nq < 0 or nq > 99 then raise exception 'Quantidade inválida.'; end if;
    oq := (it->>'qty')::int;
    sp := coalesce((it->>'semPreco')::boolean, false);
    delta := nq - oq;
    if delta <> 0 and not sp and ped.reduzido then
      select * into prod from public.produtos where id = (it->>'id')::int for update;
      if found then
        if delta > 0 and prod.estoque < delta * coalesce((it->>'unidades')::int, 1) then
          raise exception 'Estoque insuficiente para %.', prod.nome;
        end if;
        update public.produtos set estoque = estoque - delta * coalesce((it->>'unidades')::int, 1), atualizado_em = now() where id = prod.id;
      end if;
    end if;
    if nq > 0 then
      novos := novos || jsonb_build_array(jsonb_set(it, '{qty}', to_jsonb(nq)));
      if not sp then subtotal := subtotal + (it->>'unit')::numeric * nq; end if;
    end if;
    k := k + 1;
  end loop;
  if jsonb_array_length(novos) = 0 then raise exception 'O pedido precisa ter pelo menos um item. Para encerrar, cancele o pedido.'; end if;
  desc_novo := ped.desconto;
  if ped.desconto is not null then
    pct := coalesce((ped.desconto->>'pct')::numeric, 0);
    if subtotal > 0 and pct > 0 then
      desc_novo := jsonb_set(ped.desconto, '{valor}', to_jsonb(round(subtotal * pct / 100, 2)));
    else
      desc_novo := null;
    end if;
  end if;
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  update public.pedidos set itens = novos, desconto = desc_novo where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, motivo, por)
  values (p_pedido, 'edicao', true, 'Os itens do seu pedido foram ajustados pela loja.', mot, quem) returning id into ev;
  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, 'Itens do pedido ajustados', 'Os itens do seu pedido foram ajustados pela loja. Confira em Rastrear pedido.', mot, ev);
end $$;
revoke all on function public.editar_itens_pedido(bigint, jsonb, text) from public, anon;
grant execute on function public.editar_itens_pedido(bigint, jsonb, text) to authenticated;

create or replace function public.editar_endereco_pedido(p_pedido bigint, p_dest jsonb, p_obs_entregador text, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare
  ped public.pedidos;
  quem text;
  erro text;
  ev uuid;
  mot text := nullif(btrim(coalesce(p_motivo, '')), '');
  dest jsonb;
begin
  if not public.eh_gestao() then raise exception 'Sem permissão para alterar pedidos.'; end if;
  if mot is null then raise exception 'Informe o motivo da alteração (o cliente será avisado).'; end if;
  select * into ped from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if ped.status in ('entregue','cancelado') then raise exception 'Este pedido já foi encerrado.'; end if;
  erro := public.erro_endereco(p_dest);
  if erro is not null then raise exception '%', erro; end if;
  dest := jsonb_build_object(
    'cep', left(btrim(p_dest->>'cep'), 12), 'uf', upper(left(btrim(p_dest->>'uf'), 2)),
    'cidade', left(btrim(p_dest->>'cidade'), 80), 'bairro', left(btrim(p_dest->>'bairro'), 80),
    'rua', left(btrim(p_dest->>'rua'), 120), 'num', left(btrim(p_dest->>'num'), 20),
    'comp', left(btrim(coalesce(p_dest->>'comp', '')), 60), 'ref', left(btrim(coalesce(p_dest->>'ref', '')), 120));
  select coalesce(nome, 'Equipe') into quem from public.perfis where id = auth.uid();
  update public.pedidos
     set entrega = entrega || jsonb_build_object('dest', dest, 'obsEntregador', left(btrim(coalesce(p_obs_entregador, '')), 300))
   where id = p_pedido;
  insert into public.pedido_eventos (pedido_id, tipo, publico, texto, motivo, por)
  values (p_pedido, 'edicao', true, 'O endereço de entrega do seu pedido foi ajustado pela loja.', mot, quem) returning id into ev;
  insert into public.pedido_avisos (pedido_id, titulo, texto, motivo, evento_id)
  values (p_pedido, 'Endereço de entrega ajustado', 'O endereço de entrega do seu pedido foi ajustado pela loja. Confira em Rastrear pedido.', mot, ev);
end $$;
revoke all on function public.editar_endereco_pedido(bigint, jsonb, text, text) from public, anon;
grant execute on function public.editar_endereco_pedido(bigint, jsonb, text, text) to authenticated;

-- configuração de taxas e prazos (só equipe lê, só administrador grava)
insert into public.configuracao (chave, valor, publica)
values ('cartao', '{"taxaCredito":3.5,"taxaDebito":1.5,"taxaPix":0,"prazoCredito":30,"prazoDebito":1,"prazoPix":0}'::jsonb, false)
on conflict (chave) do nothing;
