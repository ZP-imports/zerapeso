-- =====================================================================
-- ZP Imports | Produtos sob consulta (preço no WhatsApp)
-- 1) Produtos podem ficar sem preço e marcados "sob consulta".
-- 2) Troca os 5 produtos de exemplo pelos 7 produtos injetáveis reais.
-- 3) Novo número de WhatsApp da loja.
-- 4) O servidor passa a RECUSAR pedido com produto sob consulta.
-- Rode depois do 01, 02, 03 e 04. Pode rodar mais de uma vez.
-- Como usar: SQL Editor > nova consulta > cole TUDO > Run.
-- =====================================================================

alter table public.produtos alter column preco drop not null;
alter table public.produtos add column if not exists sob_consulta boolean not null default false;

-- produtos de exemplo saem
delete from public.produtos where id in (1, 2, 3, 4, 5);

-- acessórios passam a ter a categoria "Acessórios de aplicação" (sem "Medicamentos")
update public.produtos set categoria = array['Acessórios de aplicação', 'Agulhas']::text[] where id = 6;
update public.produtos set categoria = array['Acessórios de aplicação', 'Seringas']::text[] where id = 7;
update public.produtos set categoria = array['Acessórios de aplicação', 'Álcool e Algodão']::text[] where id = 8;

-- produtos injetáveis (sem preço: o cliente consulta pelo WhatsApp)
insert into public.produtos (id, sku, nome, descricao, preco, estoque, ativo, categoria, cor, icone, sob_consulta) values
  (101, '5831', 'TG Tirzepatida', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#074d40', 'inj', true),
  (102, '9274', 'TIRZEC', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#0a6e5c', 'inj', true),
  (103, '1648', 'Retatrutida', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#0b5a8a', 'inj', true),
  (104, '7062', 'TIRZEDRAL', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#7a4ea0', 'inj', true),
  (105, '3915', 'GLUCONEX', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#2f6f8f', 'inj', true),
  (106, '8427', 'T36', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#6b4fa0', 'inj', true),
  (107, '2159', 'LIPOLAND', 'Produto sob consulta. Fale com a nossa equipe pelo WhatsApp para saber valores, disponibilidade e condições.', null, 0, true, array['Produtos injetáveis','Produtos especializados']::text[], '#b97a00', 'inj', true)
on conflict (id) do nothing;

-- WhatsApp da loja
update public.configuracao
   set valor = jsonb_set(valor, '{wa}', '"551231973615"'::jsonb), atualizado_em = now()
 where chave = 'site';

-- O servidor recusa produto sob consulta no pedido (função atualizada)
create or replace function public.criar_pedido(
  p_itens jsonb,
  p_entrega jsonb,
  p_codigo text default null,
  p_usar_credito boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  eu public.perfis;
  logi jsonb := public.cfg('logistica');
  prim jsonb := public.cfg('primeira_compra');
  hoje date := public.hoje_br();
  linha jsonb;
  prod public.produtos;
  qtd int;
  opt text;
  itens jsonb := '[]'::jsonb;
  subtotal numeric := 0;
  unit numeric;
  data_ent date;
  turno text;
  erro text;
  dest jsonb;
  sec jsonb;
  entrega jsonb;
  v_prim numeric := 0;
  v_ind numeric := 0;
  v_cred numeric := 0;
  pct_prim numeric;
  ind jsonb;
  cred jsonb;
  d_tipo text;
  d_pct numeric;
  d_valor numeric := 0;
  desconto jsonb;
  indicacao jsonb;
  seq_novo int;
  novo public.pedidos;
begin
  if uid is null then raise exception 'Entre na sua conta para finalizar o pedido.'; end if;
  select * into eu from public.perfis where id = uid and ativo;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if btrim(eu.nome) = '' or eu.fone is null then raise exception 'Complete o seu cadastro (nome e telefone) antes de finalizar.'; end if;
  erro := public.erro_endereco(eu.endereco);
  if erro is not null then raise exception 'Complete o endereço principal: %', erro; end if;

  -- itens: o preço vem da tabela de produtos
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O carrinho está vazio.';
  end if;
  for linha in select * from jsonb_array_elements(p_itens) loop
    begin
      qtd := (linha->>'qty')::int;
    exception when others then
      raise exception 'Quantidade inválida.';
    end;
    if qtd is null or qtd < 1 or qtd > 99 then raise exception 'Quantidade inválida.'; end if;
    select * into prod from public.produtos where id = (linha->>'id')::int and ativo and not sob_consulta for update;
    if not found then raise exception 'Um dos produtos não está mais disponível.'; end if;
    opt := coalesce(linha->>'opt', '');
    if prod.opcoes is not null and array_length(prod.opcoes, 1) > 0 then
      if not (opt = any (prod.opcoes)) then raise exception 'Escolha uma opção válida para %.', prod.nome; end if;
    else
      opt := '';
    end if;
    if prod.estoque < qtd then raise exception 'Estoque insuficiente para %.', prod.nome; end if;
    update public.produtos set estoque = estoque - qtd, atualizado_em = now() where id = prod.id;
    unit := coalesce(prod.preco_promo, prod.preco);
    subtotal := subtotal + unit * qtd;
    itens := itens || jsonb_build_array(jsonb_build_object(
      'id', prod.id, 'sku', prod.sku,
      'name', prod.nome || case when opt <> '' then ' (' || opt || ')' else '' end,
      'base', prod.nome, 'opt', opt, 'qty', qtd, 'unit', unit));
  end loop;

  -- entrega: data, turno e endereço
  begin
    data_ent := (p_entrega->>'data')::date;
  exception when others then
    raise exception 'Data de entrega inválida.';
  end;
  if data_ent is null then raise exception 'Escolha a data desejada para receber o pedido.'; end if;
  turno := coalesce(p_entrega->>'turno', '');
  if turno not in ('manha','tarde','noite') or coalesce(logi->'turnos'->>turno, 'false') <> 'true' then
    raise exception 'Escolha um turno disponível.';
  end if;
  if data_ent < hoje + coalesce((logi->>'antecedencia')::int, 1) then
    raise exception 'A data deve ser a partir de %.', to_char(hoje + coalesce((logi->>'antecedencia')::int, 1), 'DD/MM/YYYY');
  end if;
  if data_ent > hoje + coalesce((logi->>'janela')::int, 30) then
    raise exception 'A data deve ser até %.', to_char(hoje + coalesce((logi->>'janela')::int, 30), 'DD/MM/YYYY');
  end if;
  if not ((logi->'dias') @> to_jsonb(extract(dow from data_ent)::int)) then
    raise exception 'Não entregamos neste dia da semana. Escolha outra data.';
  end if;
  if exists (select 1 from jsonb_array_elements_text(coalesce(logi->'bloqueados', '[]'::jsonb)) b where b = data_ent::text) then
    raise exception 'Não há entregas nesta data. Escolha outra.';
  end if;
  sec := p_entrega->'sec';
  if sec is not null and jsonb_typeof(sec) = 'object' then
    erro := public.erro_endereco(sec, 'Endereço secundário: ');
    if erro is not null then raise exception '%', erro; end if;
    dest := jsonb_set(sec, '{uf}', to_jsonb(upper(sec->>'uf')));
  else
    sec := null;
    dest := eu.endereco;
  end if;

  -- desconto: um só por pedido, vale o maior (empate: indicação, depois crédito, depois primeira compra)
  if not exists (select 1 from public.pedidos where usuario_id = uid and status <> 'cancelado') then
    pct_prim := coalesce((prim->>'pct')::numeric, 0);
    v_prim := round(subtotal * pct_prim / 100, 2);
  end if;
  if p_codigo is not null and btrim(p_codigo) <> '' then
    ind := public.validar_indicacao(p_codigo);
    if coalesce((ind->>'ok')::boolean, false) then
      v_ind := round(subtotal * (ind->>'pct')::numeric / 100, 2);
    else
      ind := null;
    end if;
  end if;
  if p_usar_credito then
    cred := public.creditos_de(uid);
    if coalesce((cred->>'disponiveis')::int, 0) > 0 then
      v_cred := round(subtotal * (cred->>'pct')::numeric / 100, 2);
    end if;
  end if;
  if v_ind > 0 and v_ind >= v_cred and v_ind >= v_prim then
    d_tipo := 'indicacao'; d_valor := v_ind; d_pct := (ind->>'pct')::numeric;
  elsif v_cred > 0 and v_cred >= v_prim then
    d_tipo := 'credito'; d_valor := v_cred; d_pct := (cred->>'pct')::numeric;
  elsif v_prim > 0 then
    d_tipo := 'primeira'; d_valor := v_prim; d_pct := pct_prim;
  end if;
  if d_tipo is not null then
    desconto := jsonb_build_object('tipo', d_tipo, 'pct', d_pct, 'valor', d_valor);
    if d_tipo = 'indicacao' then
      desconto := desconto || jsonb_build_object('code', ind->>'codigo');
      indicacao := jsonb_build_object('owner', ind->>'owner', 'code', ind->>'codigo');
    end if;
  end if;

  select coalesce(max(seq), 0) + 1 into seq_novo from public.pedidos where usuario_id = uid;
  entrega := jsonb_build_object(
    'nome', btrim(eu.nome || ' ' || eu.sobrenome), 'fone', eu.fone,
    'principal', eu.endereco, 'secundario', sec, 'dest', dest,
    'data', data_ent::text, 'turno', turno, 'obs', left(btrim(coalesce(p_entrega->>'obs', '')), 500));

  insert into public.pedidos (usuario_id, seq, itens, entrega, desconto, indicacao, reduzido)
  values (uid, seq_novo, itens, entrega, desconto, indicacao, true)
  returning * into novo;

  insert into public.pedido_eventos (pedido_id, tipo, para, publico, texto, por)
  values (novo.id, 'status', 'realizado', true, 'Recebemos o seu pedido.', 'Cliente');

  if d_tipo = 'indicacao' and eu.indicado_por is null then
    update public.perfis set indicado_por = (ind->>'owner')::uuid where id = uid;
  end if;

  return jsonb_build_object(
    'id', novo.id,
    'codigo', 'ZP-' || lpad(novo.id::text, 6, '0'),
    'token', novo.token,
    'subtotal', subtotal,
    'desconto', coalesce(d_valor, 0),
    'total', subtotal - coalesce(d_valor, 0),
    'tipo_desconto', d_tipo);
end $$;
revoke all on function public.criar_pedido(jsonb, jsonb, text, boolean) from public, anon;
grant execute on function public.criar_pedido(jsonb, jsonb, text, boolean) to authenticated;
