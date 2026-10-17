-- Tab tracks: on days with 2+ tab tracks from one plan, athletes see tabs at the top and do every tab
-- (each is its own session with its own Complete). is_option stays "pick one" (FNDN).
-- Builder saves leave this column alone, so it survives edits in the program builder.
alter table public.programs add column if not exists is_tab boolean not null default false;
