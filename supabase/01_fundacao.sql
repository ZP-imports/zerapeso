-- =====================================================================
-- ZP Imports | Fase 1: fundação do banco
-- Tabelas, perfis, regras de acesso (RLS) e dados iniciais.
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
-- Pode ser executado mais de uma vez sem duplicar nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Perfis (um por pessoa que faz login: clientes e equipe)
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  nome text not null default '',
  sobrenome text not null default '',
  fone text,
  sem9 boolean not null default false,
  endereco jsonb,
  codigo_indicacao text unique,
  indicado_por uuid references public.perfis(id),
  consentimento_em timestamptz,
  papel text not null default 'cliente' check (papel in ('cliente','admin','logistica','separador')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Funções que dizem quem está logado (rodam sem esbarrar nas regras de acesso)
create or replace function public.papel_atual() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid() and ativo
$$;

create or replace function public.eh_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() in ('admin','logistica','separador'), false)
$$;

create or replace function public.eh_gestao() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() in ('admin','logistica'), false)
$$;

create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.papel_atual() = 'admin', false)
$$;

-- Quando alguém se cadastra, o perfil nasce sozinho. O papel é SEMPRE "cliente".
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  n text := coalesce(m->>'nome', '');
  base text;
  cod text;
  tentativas int := 0;
  f text := m->>'fone';
begin
  base := upper(left(
    regexp_replace(
      translate(n, 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ', 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC'),
      '[^A-Za-z]', '', 'g') || 'XXX', 3));
  loop
    cod := 'ZP' || base || lpad((floor(random() * 9000) + 1000)::int::text, 4, '0');
    exit when not exists (select 1 from public.perfis where codigo_indicacao = cod) or tentativas > 20;
    tentativas := tentativas + 1;
  end loop;
  if f is not null and length(regexp_replace(f, '\D', '', 'g')) not between 10 and 11 then
    f := null;
  end if;
  insert into public.perfis (id, email, nome, sobrenome, fone, sem9, codigo_indicacao, consentimento_em)
  values (
    new.id, new.email, n, coalesce(m->>'sobrenome', ''), f,
    case when m->>'sem9' = 'true' then true else false end,
    cod,
    case when m->>'consentimento' = 'true' then now() end
  );
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
for each row execute function public.novo_usuario();

-- O cliente não pode mudar o próprio papel, e-mail, código de indicação etc.
create or replace function public.proteger_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.eh_admin() then
    if new.id <> old.id
       or new.papel is distinct from old.papel
       or new.ativo is distinct from old.ativo
       or new.email is distinct from old.email
       or new.codigo_indicacao is distinct from old.codigo_indicacao
       or new.indicado_por is distinct from old.indicado_por then
      raise exception 'Você não pode alterar esses campos do perfil.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists proteger_perfil_trg on public.perfis;
create trigger proteger_perfil_trg before update on public.perfis
for each row execute function public.proteger_perfil();

-- Só administrador define o papel de alguém da equipe
create or replace function public.definir_papel(p_email text, p_papel text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then
    raise exception 'Apenas administradores podem definir papéis.';
  end if;
  if p_papel not in ('cliente','admin','logistica','separador') then
    raise exception 'Papel inválido.';
  end if;
  update public.perfis set papel = p_papel where lower(email) = lower(p_email);
  if not found then
    raise exception 'Usuário não encontrado.';
  end if;
end $$;
revoke all on function public.definir_papel(text, text) from public, anon;
grant execute on function public.definir_papel(text, text) to authenticated;

alter table public.perfis enable row level security;
drop policy if exists perfis_ler_proprio on public.perfis;
create policy perfis_ler_proprio on public.perfis for select to authenticated using (id = auth.uid());
drop policy if exists perfis_ler_equipe on public.perfis;
create policy perfis_ler_equipe on public.perfis for select to authenticated using (public.eh_equipe());
drop policy if exists perfis_editar_proprio on public.perfis;
create policy perfis_editar_proprio on public.perfis for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists perfis_editar_admin on public.perfis;
create policy perfis_editar_admin on public.perfis for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- ---------------------------------------------------------------------
-- 2. Produtos
-- ---------------------------------------------------------------------
create table if not exists public.produtos (
  id int primary key,
  sku text unique not null,
  nome text not null,
  descricao text not null default '',
  preco numeric(10,2) not null check (preco >= 0),
  preco_promo numeric(10,2) check (preco_promo is null or preco_promo >= 0),
  estoque int not null default 0 check (estoque >= 0),
  ativo boolean not null default true,
  categoria text[] not null default '{}',
  opcoes text[],
  rotulo_opcao text,
  cor text,
  icone text,
  atualizado_em timestamptz not null default now()
);

alter table public.produtos enable row level security;
drop policy if exists produtos_ler on public.produtos;
create policy produtos_ler on public.produtos for select to anon, authenticated using (ativo or public.eh_equipe());
drop policy if exists produtos_inserir on public.produtos;
create policy produtos_inserir on public.produtos for insert to authenticated with check (public.eh_admin());
drop policy if exists produtos_editar on public.produtos;
create policy produtos_editar on public.produtos for update to authenticated using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists produtos_apagar on public.produtos;
create policy produtos_apagar on public.produtos for delete to authenticated using (public.eh_admin());

-- ---------------------------------------------------------------------
-- 3. Entregadores, rotas e retiradas
-- ---------------------------------------------------------------------
create table if not exists public.entregadores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  whats text not null,
  sem9 boolean not null default false,
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
create unique index if not exists entregadores_whats_unico on public.entregadores ((regexp_replace(whats, '\D', '', 'g')));

create table if not exists public.rotas (
  id uuid primary key default gen_random_uuid(),
  n int generated by default as identity unique,
  data date not null,
  entregador_id uuid not null references public.entregadores(id),
  pedidos bigint[] not null default '{}',
  criada_em timestamptz not null default now(),
  enviada_em timestamptz,
  saiu_em timestamptz,
  por text
);

create table if not exists public.retiradas (
  id uuid primary key default gen_random_uuid(),
  n int generated by default as identity unique,
  data date not null,
  total numeric(12,2) not null default 0,
  pedidos bigint[] not null default '{}',
  criada_em timestamptz not null default now(),
  por text
);

alter table public.entregadores enable row level security;
drop policy if exists entregadores_ler on public.entregadores;
create policy entregadores_ler on public.entregadores for select to authenticated using (public.eh_gestao());
drop policy if exists entregadores_inserir on public.entregadores;
create policy entregadores_inserir on public.entregadores for insert to authenticated with check (public.eh_gestao());
drop policy if exists entregadores_editar on public.entregadores;
create policy entregadores_editar on public.entregadores for update to authenticated using (public.eh_gestao()) with check (public.eh_gestao());

alter table public.rotas enable row level security;
drop policy if exists rotas_ler on public.rotas;
create policy rotas_ler on public.rotas for select to authenticated using (public.eh_gestao());
drop policy if exists rotas_inserir on public.rotas;
create policy rotas_inserir on public.rotas for insert to authenticated with check (public.eh_gestao());
drop policy if exists rotas_editar on public.rotas;
create policy rotas_editar on public.rotas for update to authenticated using (public.eh_gestao()) with check (public.eh_gestao());
drop policy if exists rotas_apagar on public.rotas;
create policy rotas_apagar on public.rotas for delete to authenticated using (public.eh_admin());

alter table public.retiradas enable row level security;
drop policy if exists retiradas_tudo on public.retiradas;
create policy retiradas_tudo on public.retiradas for all to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- ---------------------------------------------------------------------
-- 4. Pedidos, eventos, avisos e etiquetas
-- ---------------------------------------------------------------------
create table if not exists public.pedidos (
  id bigint generated by default as identity (start with 100) primary key,
  usuario_id uuid not null references public.perfis(id),
  seq int not null default 1,
  status text not null default 'realizado' check (status in
    ('realizado','confirmado','preparacao','separacao','aguardando-programacao','programada','em-rota','entregue','tentativa','cancelado')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  itens jsonb not null,
  entrega jsonb not null,
  pagamento jsonb not null default '{"modo":"link","status":"pendente","taxaEntrega":0}'::jsonb,
  desconto jsonb,
  indicacao jsonb,
  rastreio jsonb,
  token text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 16),
  rota_id uuid references public.rotas(id) on delete set null,
  entregador_id uuid references public.entregadores(id) on delete set null,
  conf_n int,
  reduzido boolean not null default false,
  obs_interna text,
  obs_separacao text,
  motivo_atraso text,
  msg_pagamento jsonb,
  wa_pendente jsonb,
  extra jsonb not null default '{}'::jsonb
);
create index if not exists pedidos_usuario_idx on public.pedidos (usuario_id);
create index if not exists pedidos_status_idx on public.pedidos (status);
create index if not exists pedidos_criado_idx on public.pedidos (criado_em desc);

create or replace function public.tocar_atualizado() returns trigger
language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;
drop trigger if exists pedidos_atualizado on public.pedidos;
create trigger pedidos_atualizado before update on public.pedidos
for each row execute function public.tocar_atualizado();

create table if not exists public.pedido_eventos (
  id uuid primary key default gen_random_uuid(),
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  t timestamptz not null default now(),
  tipo text not null,
  de text,
  para text,
  publico boolean not null default false,
  texto text,
  motivo text,
  por text,
  extra jsonb not null default '{}'::jsonb
);
create index if not exists eventos_pedido_idx on public.pedido_eventos (pedido_id, t);

create table if not exists public.pedido_avisos (
  id uuid primary key default gen_random_uuid(),
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  t timestamptz not null default now(),
  titulo text not null,
  texto text not null default '',
  lido boolean not null default false,
  motivo text,
  previsao jsonb,
  evento_id uuid
);
create index if not exists avisos_pedido_idx on public.pedido_avisos (pedido_id, t);

create table if not exists public.etiquetas (
  id uuid primary key default gen_random_uuid(),
  pedido_id bigint not null references public.pedidos(id) on delete cascade,
  v int not null,
  hash text not null,
  snap jsonb not null,
  cfg jsonb,
  status text not null default 'atual',
  motivo text,
  por text,
  arquivo_path text,
  criado_em timestamptz not null default now(),
  unique (pedido_id, v)
);

alter table public.pedidos enable row level security;
drop policy if exists pedidos_ler_proprio on public.pedidos;
create policy pedidos_ler_proprio on public.pedidos for select to authenticated using (usuario_id = auth.uid());
drop policy if exists pedidos_ler_equipe on public.pedidos;
create policy pedidos_ler_equipe on public.pedidos for select to authenticated using (public.eh_equipe());
drop policy if exists pedidos_editar_gestao on public.pedidos;
create policy pedidos_editar_gestao on public.pedidos for update to authenticated using (public.eh_gestao()) with check (public.eh_gestao());
-- Não existe política de inserir nem de apagar: o cliente cria pedido só pela função segura da Fase 2.

alter table public.pedido_eventos enable row level security;
drop policy if exists eventos_ler_cliente on public.pedido_eventos;
create policy eventos_ler_cliente on public.pedido_eventos for select to authenticated
  using (publico and exists (select 1 from public.pedidos p where p.id = pedido_id and p.usuario_id = auth.uid()));
drop policy if exists eventos_ler_equipe on public.pedido_eventos;
create policy eventos_ler_equipe on public.pedido_eventos for select to authenticated using (public.eh_equipe());
drop policy if exists eventos_inserir_equipe on public.pedido_eventos;
create policy eventos_inserir_equipe on public.pedido_eventos for insert to authenticated with check (public.eh_equipe());

alter table public.pedido_avisos enable row level security;
drop policy if exists avisos_ler_cliente on public.pedido_avisos;
create policy avisos_ler_cliente on public.pedido_avisos for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id and p.usuario_id = auth.uid()));
drop policy if exists avisos_ler_equipe on public.pedido_avisos;
create policy avisos_ler_equipe on public.pedido_avisos for select to authenticated using (public.eh_equipe());
drop policy if exists avisos_inserir_equipe on public.pedido_avisos;
create policy avisos_inserir_equipe on public.pedido_avisos for insert to authenticated with check (public.eh_equipe());

alter table public.etiquetas enable row level security;
drop policy if exists etiquetas_equipe on public.etiquetas;
create policy etiquetas_equipe on public.etiquetas for all to authenticated using (public.eh_equipe()) with check (public.eh_equipe());

-- O cliente marca os próprios avisos como lidos (só isso)
create or replace function public.marcar_avisos_lidos(p_pedido bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.pedido_avisos a set lido = true
  where a.pedido_id = p_pedido
    and exists (select 1 from public.pedidos p where p.id = p_pedido and p.usuario_id = auth.uid());
end $$;
revoke all on function public.marcar_avisos_lidos(bigint) from public, anon;
grant execute on function public.marcar_avisos_lidos(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Configurações e rotas previstas
-- ---------------------------------------------------------------------
create table if not exists public.configuracao (
  chave text primary key,
  valor jsonb not null,
  publica boolean not null default false,
  atualizado_em timestamptz not null default now()
);

alter table public.configuracao enable row level security;
drop policy if exists config_ler_publica on public.configuracao;
create policy config_ler_publica on public.configuracao for select to anon, authenticated using (publica);
drop policy if exists config_ler_equipe on public.configuracao;
create policy config_ler_equipe on public.configuracao for select to authenticated using (public.eh_equipe());
drop policy if exists config_inserir on public.configuracao;
create policy config_inserir on public.configuracao for insert to authenticated with check (public.eh_admin());
drop policy if exists config_editar on public.configuracao;
create policy config_editar on public.configuracao for update to authenticated using (public.eh_admin()) with check (public.eh_admin());
drop policy if exists config_apagar on public.configuracao;
create policy config_apagar on public.configuracao for delete to authenticated using (public.eh_admin());

create table if not exists public.rotas_previstas (
  chave text primary key,
  dados jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.rotas_previstas enable row level security;
drop policy if exists rotas_prev_ler on public.rotas_previstas;
create policy rotas_prev_ler on public.rotas_previstas for select to authenticated using (true);
drop policy if exists rotas_prev_inserir on public.rotas_previstas;
create policy rotas_prev_inserir on public.rotas_previstas for insert to authenticated with check (public.eh_gestao());
drop policy if exists rotas_prev_editar on public.rotas_previstas;
create policy rotas_prev_editar on public.rotas_previstas for update to authenticated using (public.eh_gestao()) with check (public.eh_gestao());
drop policy if exists rotas_prev_apagar on public.rotas_previstas;
create policy rotas_prev_apagar on public.rotas_previstas for delete to authenticated using (public.eh_gestao());

create table if not exists public.alertas_vistos (
  usuario_id uuid not null references public.perfis(id) on delete cascade,
  alerta_id text not null,
  visto_em timestamptz not null default now(),
  primary key (usuario_id, alerta_id)
);
alter table public.alertas_vistos enable row level security;
drop policy if exists alertas_proprios on public.alertas_vistos;
create policy alertas_proprios on public.alertas_vistos for all to authenticated
  using (usuario_id = auth.uid() and public.eh_equipe()) with check (usuario_id = auth.uid() and public.eh_equipe());

-- ---------------------------------------------------------------------
-- 6. Dados iniciais
-- ---------------------------------------------------------------------
insert into public.configuracao (chave, valor, publica) values
 ('site', '{"brand":"ZP Imports","wa":"5512999990000","frete":"Informada pela loja","faixa":"Medicamentos para emagrecimento: {pct}%OFF na sua primeira compra","aviso":"Medicamentos devem ser usados com moderação. Leia a bula e siga as orientações da equipe."}', true),
 ('primeira_compra', '{"pct":10}', true),
 ('amigo', '{"ativa":true,"nome":"Amigo Emagrece Amigo, campanha Out/Nov 2026","pct":10,"inicio":"2026-10-01","fim":"2026-11-30","limite":10}', true),
 ('logistica', '{"turnos":{"manha":true,"tarde":true,"noite":true},"antecedencia":1,"janela":30,"dias":[1,2,3,4,5,6],"bloqueados":[],"atrasoHoras":24,"alertaAmarelo":12,"alertaLaranja":20,"fim":{"manha":12,"tarde":18,"noite":22}}', true),
 ('pagamento', '{"linkPag":""}', false),
 ('etiquetas', '{"w":100,"h":150,"m":4,"fs":9,"barcodePos":"rodape","logoH":16,"remetente":"ZP IMPORTS","remEnd":"Centro, Jacareí/SP"}', false),
 ('cartao', '{"taxaCredito":3.5,"taxaDebito":1.5,"taxaPix":0,"prazoCredito":30,"prazoDebito":1,"prazoPix":0}', false)
on conflict (chave) do nothing;

insert into public.produtos (id, sku, nome, descricao, preco, preco_promo, estoque, ativo, categoria, opcoes, rotulo_opcao, cor, icone) values
 (1, 'MED-101', 'Medicamento injetável para emagrecimento, caneta (exemplo)', 'Produto de exemplo. Cadastre aqui o nome, a descrição e a apresentação reais do medicamento.', 899.00, null, 8, true, array['Medicamentos','Injetáveis','Canetas Aplicadoras']::text[], array['Caixa com 1 caneta','Caixa com 4 canetas']::text[], 'Apresentação', '#0a6e5c', 'inj'),
 (2, 'MED-103', 'Medicamento injetável para emagrecimento, caneta dose maior (exemplo)', 'Produto de exemplo. Cadastre aqui o nome, a descrição e a apresentação reais do medicamento.', 1199.00, null, 5, true, array['Medicamentos','Injetáveis','Canetas Aplicadoras']::text[], array['Caixa com 1 caneta','Caixa com 4 canetas']::text[], 'Apresentação', '#074d40', 'inj'),
 (3, 'MED-102', 'Medicamento oral para emagrecimento, 30 comprimidos (exemplo)', 'Produto de exemplo. Cadastre aqui o nome, a descrição e a apresentação reais do medicamento.', 249.00, null, 20, true, array['Medicamentos','Orais','Comprimidos']::text[], null, null, '#0b5a8a', 'pill'),
 (4, 'MED-105', 'Medicamento oral para emagrecimento, 60 comprimidos (exemplo)', 'Produto de exemplo. Cadastre aqui o nome, a descrição e a apresentação reais do medicamento.', 419.00, null, 12, true, array['Medicamentos','Orais','Comprimidos']::text[], null, null, '#2f6f8f', 'pill'),
 (5, 'MED-104', 'Medicamento oral para emagrecimento, 60 cápsulas (exemplo)', 'Produto de exemplo. Cadastre aqui o nome, a descrição e a apresentação reais do medicamento.', 289.00, null, 15, true, array['Medicamentos','Orais','Cápsulas']::text[], null, null, '#7a4ea0', 'caps'),
 (6, 'ACE-101', 'Agulhas para caneta aplicadora, caixa com 100', 'Agulhas descartáveis para uso com canetas aplicadoras.', 59.90, 49.90, 60, true, array['Medicamentos','Acessórios de Aplicação','Agulhas']::text[], null, null, '#0a6e5c', 'needle'),
 (7, 'ACE-102', 'Seringas descartáveis, caixa com 10', 'Seringas descartáveis.', 24.90, null, 40, true, array['Medicamentos','Acessórios de Aplicação','Seringas']::text[], null, null, '#0b5a8a', 'needle'),
 (8, 'ACE-103', 'Álcool 70% 1 litro', 'Para higienizar o local da aplicação.', 12.90, 9.90, 50, true, array['Medicamentos','Acessórios de Aplicação','Álcool e Algodão']::text[], null, null, '#2f7d6d', 'bottle'),
 (15, 'BON-003', 'Fita Métrica Corporal', 'Para acompanhar suas medidas.', 19.90, null, 5, false, array['Acompanhamento','Medidas','Fitas Métricas']::text[], null, null, '#6b4fa0', 'tape'),
 (16, 'MOC-004', 'Balança Digital Corporal', 'Balança digital com display.', 199.00, null, 0, false, array['Acompanhamento','Medidas','Balanças']::text[], null, null, '#6c7a74', 'scale')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 7. Conferência (rode depois, se quiser): lista as tabelas e se a proteção está ligada
-- ---------------------------------------------------------------------
-- select c.relname as tabela, c.relrowsecurity as protegida
--   from pg_class c join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public' and c.relkind = 'r' order by 1;

-- ---------------------------------------------------------------------
-- 8. Primeira pessoa administradora (faça UMA vez, depois de criar o usuário em
--    Authentication > Users > Add user, marcando "Auto Confirm User")
-- ---------------------------------------------------------------------
-- update public.perfis set papel = 'admin' where lower(email) = lower('SEU-EMAIL-AQUI');
