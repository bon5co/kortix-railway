# kortix-railway

Railway wrapper images for [Kortix](https://github.com/kortix-ai/suna) 0.16.4 (Elastic License 2.0), used by the Railway template "Kortix | (Just Updated) ...".

Eight images, one per service, each built `FROM` the pinned upstream image (Kortix api, gateway and frontend; Supabase Postgres, GoTrue and Storage; PostgREST; Kong). They share one boot script, `railway-boot.sh`, selected by `KORTIX_ROLE`. The script applies what Railway needs: private hosts under `*.railway.internal`, public services on the injected `PORT`, secrets from template variables, closed sign-up, and one admin login created at boot from `ADMIN_EMAIL` / `ADMIN_PASSWORD`.

The wrapper is derived from the boot script of Kortix's own one-click blueprint. The Elastic License 2.0 forbids offering Kortix to third parties as a hosted or managed service; deploy it for your own use.
