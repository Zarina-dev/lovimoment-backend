-- ════════════════════════════════════════════════════════════════════
--  Lovi moment — Supabase schema, roles and Row Level Security
--  Run once in Supabase → SQL Editor. Safe to re-run (idempotent).
--  Column names are snake_case; the app maps them to camelCase.
-- ════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── Profiles & roles ────────────────────────────────────────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  role text not null default 'user' check (role in ('user', 'editor', 'admin')),
  created_at timestamptz not null default now()
);

-- Create a profile automatically for every new auth user (role = user).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name) values (new.id, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Role checks used by every RLS policy. SECURITY DEFINER avoids RLS recursion.
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role in ('admin', 'editor'));
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- Generic updated_at trigger
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ── Content tables ──────────────────────────────────────────────────
create table if not exists public.destinations (
  id text primary key default gen_random_uuid()::text,
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name jsonb not null default '{}',
  tagline jsonb not null default '{}',
  description jsonb not null default '{}',
  best_time jsonb not null default '{}',
  highlights jsonb not null default '{}',
  image text,
  featured boolean not null default true,
  published boolean not null default true,
  "order" int not null default 99,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.guides (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  role jsonb not null default '{}',
  bio jsonb not null default '{}',
  languages jsonb not null default '[]',
  photo text,
  published boolean not null default true,
  "order" int not null default 99,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tours (
  id text primary key default gen_random_uuid()::text,
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  title jsonb not null default '{}',
  location jsonb not null default '{}',
  summary jsonb not null default '{}',
  description jsonb not null default '{}',
  highlights jsonb not null default '{}',
  included jsonb not null default '{}',
  excluded jsonb not null default '{}',
  itinerary jsonb not null default '[]',
  places jsonb not null default '[]',          -- places visited, e.g. ["Бишкек","Сон-Куль"]
  guide jsonb not null default '{}',
  images jsonb not null default '[]',
  dates jsonb not null default '[]',
  group_size jsonb not null default '{"min":1,"max":12}',
  destination text not null references public.destinations (slug) on update cascade,
  category text not null check (category in ('mountain', 'cultural', 'nature', 'luxury', 'adventure')),
  type text not null default 'group' check (type in ('group', 'private')),
  difficulty text not null default 'easy' check (difficulty in ('easy', 'moderate', 'challenging')),
  duration_days int not null check (duration_days > 0),
  price numeric(10, 2) not null check (price > 0),
  rating numeric(2, 1) not null default 5 check (rating between 0 and 5),
  reviews_count int not null default 0,
  popularity int not null default 50,
  featured boolean not null default false,
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists tours_destination_idx on public.tours (destination);
-- For databases created before the "places" / "guide_id" columns existed:
alter table public.tours add column if not exists places jsonb not null default '[]';
-- Guide chosen from public.guides (the old embedded "guide" jsonb column is no longer used).
alter table public.tours add column if not exists guide_id text references public.guides (id) on delete set null;

create table if not exists public.reviews (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  country text,
  tour_slug text references public.tours (slug) on update cascade on delete set null,
  rating int not null check (rating between 1 and 5),
  date date not null default current_date,
  text text not null,
  avatar text,
  photo text,
  status text not null default 'pending' check (status in ('pending', 'published', 'hidden')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Where the review came from: 'admin' (added by staff) or 'site' (sent by a visitor).
alter table public.reviews add column if not exists source text not null default 'admin';
-- Several trip photos per review (photo = the first one, kept for older data).
alter table public.reviews add column if not exists photos jsonb not null default '[]'::jsonb;
-- «Закрепить»: pinned reviews are shown first on the site.
alter table public.reviews add column if not exists pinned boolean not null default false;

create table if not exists public.gallery_images (
  id text primary key default gen_random_uuid()::text,
  src text not null,
  caption jsonb not null default '{}',
  location text,
  "order" int not null default 99,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.site_settings (
  key text primary key,
  value jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- ── Customer data ───────────────────────────────────────────────────
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  full_name text not null check (char_length(full_name) between 2 and 100),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  phone text not null check (char_length(phone) between 7 and 25),
  country text not null check (char_length(country) between 2 and 80),
  tour_id text references public.tours (id) on delete set null,
  tour_slug text,
  tour_title text,
  travel_date date not null,
  travelers int not null check (travelers between 1 and 30),
  message text check (char_length(message) <= 1000),
  status text not null default 'new' check (status in ('new', 'contacted', 'confirmed', 'completed', 'cancelled')),
  total_estimate numeric(12, 2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bookings_status_idx on public.bookings (status, created_at desc);

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  email text not null unique,
  phone text,
  country text,
  bookings_count int not null default 0,
  last_booking_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.newsletter_subscribers (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  lang text not null default 'en' check (lang in ('en', 'ru', 'ky')),
  created_at timestamptz not null default now()
);

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 100),
  email text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  subject text check (char_length(subject) <= 150),
  message text not null check (char_length(message) between 10 and 3000),
  status text not null default 'new' check (status in ('new', 'read', 'archived')),
  created_at timestamptz not null default now()
);

-- updated_at triggers
do $$
declare t text;
begin
  foreach t in array array['destinations', 'guides', 'tours', 'reviews', 'gallery_images', 'bookings', 'customers', 'site_settings'] loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format('create trigger touch_%1$s before update on public.%1$s for each row execute function public.touch_updated_at()', t);
  end loop;
end $$;

-- Upsert a customer for every new booking (runs with definer rights, so
-- anonymous visitors never need access to the customers table).
create or replace function public.upsert_customer_from_booking()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.customers (full_name, email, phone, country, bookings_count, last_booking_at)
  values (new.full_name, lower(new.email), new.phone, new.country, 1, new.created_at)
  on conflict (email) do update
    set full_name = excluded.full_name,
        phone = excluded.phone,
        country = excluded.country,
        bookings_count = public.customers.bookings_count + 1,
        last_booking_at = excluded.last_booking_at;
  return new;
end $$;

drop trigger if exists bookings_upsert_customer on public.bookings;
create trigger bookings_upsert_customer after insert on public.bookings
  for each row execute function public.upsert_customer_from_booking();

-- ════════════════════════════════════════════════════════════════════
--  Row Level Security
-- ════════════════════════════════════════════════════════════════════
alter table public.profiles enable row level security;
alter table public.destinations enable row level security;
alter table public.tours enable row level security;
alter table public.guides enable row level security;
alter table public.reviews enable row level security;
alter table public.gallery_images enable row level security;
alter table public.site_settings enable row level security;
alter table public.bookings enable row level security;
alter table public.customers enable row level security;
alter table public.newsletter_subscribers enable row level security;
alter table public.contact_messages enable row level security;

-- Profiles: users read their own; only admins manage roles.
drop policy if exists "profiles self read" on public.profiles;
create policy "profiles self read" on public.profiles for select using (id = auth.uid() or public.is_admin());
drop policy if exists "profiles admin write" on public.profiles;
create policy "profiles admin write" on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- Public content: everyone reads published rows; staff manage everything.
drop policy if exists "destinations public read" on public.destinations;
create policy "destinations public read" on public.destinations for select using (published or public.is_staff());
drop policy if exists "destinations staff write" on public.destinations;
create policy "destinations staff write" on public.destinations for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "tours public read" on public.tours;
create policy "tours public read" on public.tours for select using (published or public.is_staff());
drop policy if exists "tours staff write" on public.tours;
create policy "tours staff write" on public.tours for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "guides public read" on public.guides;
create policy "guides public read" on public.guides for select using (published or public.is_staff());
drop policy if exists "guides staff write" on public.guides;
create policy "guides staff write" on public.guides for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "reviews public read" on public.reviews;
create policy "reviews public read" on public.reviews for select using (status = 'published' or public.is_staff());
drop policy if exists "reviews staff write" on public.reviews;
create policy "reviews staff write" on public.reviews for all using (public.is_staff()) with check (public.is_staff());
-- Visitors may SEND a review, but only as "pending" from the site; staff publish it.
drop policy if exists "reviews public submit" on public.reviews;
create policy "reviews public submit" on public.reviews for insert to anon, authenticated
  with check (
    status = 'pending'
    and source = 'site'
    and pinned = false
    and char_length(name) between 2 and 80
    and char_length(text) between 20 and 1500
    and rating between 1 and 5
    -- optional trip photos (max 5), only from the folder visitors may upload to (see Storage below)
    and (coalesce(photo, '') = '' or photo like '%/storage/v1/object/public/media/review-submissions/%.jpg')
    and jsonb_typeof(photos) = 'array'
    and jsonb_array_length(photos) <= 5
    and not exists (
      select 1 from jsonb_array_elements_text(photos) as p(url)
      where p.url not like '%/storage/v1/object/public/media/review-submissions/%.jpg'
    )
  );

drop policy if exists "gallery public read" on public.gallery_images;
create policy "gallery public read" on public.gallery_images for select using (true);
drop policy if exists "gallery staff write" on public.gallery_images;
create policy "gallery staff write" on public.gallery_images for all using (public.is_staff()) with check (public.is_staff());

drop policy if exists "settings public read" on public.site_settings;
create policy "settings public read" on public.site_settings for select using (true);
drop policy if exists "settings admin write" on public.site_settings;
create policy "settings admin write" on public.site_settings for all using (public.is_admin()) with check (public.is_admin());

-- Bookings: anyone may submit a NEW request; only staff can read it back.
drop policy if exists "bookings public insert" on public.bookings;
create policy "bookings public insert" on public.bookings for insert to anon, authenticated
  with check (status = 'new' and travel_date > current_date);
drop policy if exists "bookings staff read" on public.bookings;
create policy "bookings staff read" on public.bookings for select using (public.is_staff());
drop policy if exists "bookings staff update" on public.bookings;
create policy "bookings staff update" on public.bookings for update using (public.is_staff()) with check (public.is_staff());
drop policy if exists "bookings admin delete" on public.bookings;
create policy "bookings admin delete" on public.bookings for delete using (public.is_admin());

-- Customers: staff only (rows are created by the trigger above).
drop policy if exists "customers staff" on public.customers;
create policy "customers staff" on public.customers for all using (public.is_staff()) with check (public.is_staff());

-- Newsletter & contact: public insert, staff read/manage.
drop policy if exists "newsletter public insert" on public.newsletter_subscribers;
create policy "newsletter public insert" on public.newsletter_subscribers for insert to anon, authenticated with check (true);
drop policy if exists "newsletter staff" on public.newsletter_subscribers;
create policy "newsletter staff" on public.newsletter_subscribers for select using (public.is_staff());
drop policy if exists "newsletter admin delete" on public.newsletter_subscribers;
create policy "newsletter admin delete" on public.newsletter_subscribers for delete using (public.is_admin());

drop policy if exists "contact public insert" on public.contact_messages;
create policy "contact public insert" on public.contact_messages for insert to anon, authenticated with check (status = 'new');
drop policy if exists "contact staff" on public.contact_messages;
create policy "contact staff" on public.contact_messages for all using (public.is_staff()) with check (public.is_staff());

-- ════════════════════════════════════════════════════════════════════
--  «Недавно удалённые»: a copy of every deleted record, restorable for 30 days
--  (the admin app removes entries older than 30 days when the list is opened).
-- ════════════════════════════════════════════════════════════════════
create table if not exists public.trash (
  id uuid primary key default gen_random_uuid(),
  collection text not null,
  record jsonb not null,
  label text,
  image text,
  deleted_by uuid default auth.uid(),
  deleted_at timestamptz not null default now()
);
create index if not exists trash_deleted_idx on public.trash (deleted_at desc);
alter table public.trash enable row level security;
drop policy if exists "trash staff all" on public.trash;
create policy "trash staff all" on public.trash for all using (public.is_staff()) with check (public.is_staff());

-- ════════════════════════════════════════════════════════════════════
--  Storage: public "media" bucket, writable by staff (+ review photos from visitors)
-- ════════════════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public)
values ('media', 'media', true)
on conflict (id) do nothing;

drop policy if exists "media public read" on storage.objects;
create policy "media public read" on storage.objects for select using (bucket_id = 'media');
drop policy if exists "media staff insert" on storage.objects;
create policy "media staff insert" on storage.objects for insert with check (bucket_id = 'media' and public.is_staff());
-- Visitors may attach photos (up to 5) to a review: only new .jpg files in media/review-submissions/
-- (the site compresses photos to JPEG before upload). They cannot list, overwrite or delete files.
drop policy if exists "media review photo upload" on storage.objects;
create policy "media review photo upload" on storage.objects for insert to anon, authenticated
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = 'review-submissions'
    and lower(storage.extension(name)) = 'jpg'
  );
-- Upper bound for any single file in the bucket (admin uploads are limited to 8 MB in the UI).
update storage.buckets set file_size_limit = 10485760 where id = 'media';
drop policy if exists "media staff update" on storage.objects;
create policy "media staff update" on storage.objects for update using (bucket_id = 'media' and public.is_staff());
drop policy if exists "media staff delete" on storage.objects;
create policy "media staff delete" on storage.objects for delete using (bucket_id = 'media' and public.is_staff());

-- ════════════════════════════════════════════════════════════════════
--  Make your first admin (after creating the user in Auth → Users):
--    update public.profiles set role = 'admin'
--    where id = (select id from auth.users where email = 'you@yourdomain.com');
-- ════════════════════════════════════════════════════════════════════
