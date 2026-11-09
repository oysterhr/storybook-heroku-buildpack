# Storybook VPN gate: staging rollout and prod cutover (FLOW-1713)

A human runs these commands. The staging app is **standalone**: it has no pipeline and no custom domain.

- **Never attach it to the oyster-storybook pipeline.** `pipelines:promote` copies slugs between apps, and that is forbidden here.
- **Test only on the `*.herokuapp.com` hostname.**

## 1. Create the staging app

```sh
heroku apps:create oyster-storybook-staging --team oyster-devs --region us
heroku stack:set heroku-24 -a oyster-storybook-staging

heroku buildpacks:set heroku/nodejs -a oyster-storybook-staging
heroku buildpacks:add https://github.com/oysterhr/storybook-heroku-buildpack#vpn-gate -a oyster-storybook-staging
heroku buildpacks:add heroku-community/nginx -a oyster-storybook-staging
heroku buildpacks -a oyster-storybook-staging   # check the order: nodejs, storybook, nginx
```

Before running these, confirm the nginx buildpack reference matches what production uses (`heroku buildpacks -a oyster-storybook`). If production uses a GitHub URL, use the same one.

## 2. Config vars (copied explicitly, never cloned wholesale)

```sh
# Look up the production values (do not print secrets into shared channels):
heroku config:get NODE_OPTIONS NODE_MODULES_CACHE NPM_CONFIG_PRODUCTION YARN2_SKIP_PRUNING SKIP_SOURCEMAPS_UPLOAD -a oyster-storybook

heroku config:set -a oyster-storybook-staging \
  NODE_OPTIONS="<from prod>" \
  NODE_MODULES_CACHE="<from prod>" \
  NPM_CONFIG_PRODUCTION="<from prod>" \
  YARN2_SKIP_PRUNING="<from prod>" \
  SKIP_SOURCEMAPS_UPLOAD="<from prod>"

# NEW credentials used only on staging. Never reuse the production ones.
heroku config:set -a oyster-storybook-staging \
  BASIC_AUTH_USERNAME="storybook-staging" \
  BASIC_AUTH_PASSWORD="$(openssl rand -base64 24)"

heroku config:set -a oyster-storybook-staging \
  VPN_ALLOWED_CIDRS="95.179.220.118/32,209.35.224.184/32,131.226.43.208/32,172.235.251.116/32,185.14.187.105/32,64.226.129.141/32,64.226.128.64/32,216.238.98.228/32,139.180.190.134/32,212.59.68.116/32,5.22.218.185/32,5.22.223.158/32,149.28.246.199/32"
```

## 3. Deploy

In the Heroku dashboard, open oyster-storybook-staging, then Deploy. Connect GitHub to `oysterhr/anywhere`, choose **Manual deploy** of branch `master`, and do not enable automatic deploys.

## 4. Verify

1. Realip check (README "Verify the router range"): `heroku logs -a oyster-storybook-staging --tail | grep router_peer=`. Every peer must be inside `10.0.0.0/8` and `client_ip=` must match your egress IP. If not, fix `set_real_ip_from` on the branch and redeploy before going further.
2. `scripts/test-matrix.sh oyster-storybook-staging-<hash>.herokuapp.com on`, run while connected to the VPN.
3. `scripts/test-matrix.sh oyster-storybook-staging-<hash>.herokuapp.com off`, run with the VPN disconnected.
4. Break-glass drill: append your off-VPN `/32` (🔴 **RESTARTS staging dynos**), confirm access, remove it (🔴 restart), and confirm you get 403 again.
5. Check `heroku config:get VPN_ALLOWED_CIDRS -a oyster-storybook-staging`, and check that a deliberately malformed entry shows up as `# SKIPPED` without breaking boot.

## 5. Production cutover

1. **Pin production to the current buildpack SHA first**, so that merging the PR changes nothing by itself:
   ```sh
   heroku buildpacks -a oyster-storybook        # record the current list
   heroku buildpacks:set --index 2 https://github.com/oysterhr/storybook-heroku-buildpack#c7512ffe3bccfe2aac34e0b9c9c28d8a92569f38 -a oyster-storybook
   ```
   (`c7512ffe3bccfe2aac34e0b9c9c28d8a92569f38` is main HEAD as of this PR. Re-check it before pinning.)
2. Merge the PR. Record the merge commit SHA as `<MERGED_SHA>`.
3. Set the allowlist (🔴 **WARNING: THIS RESTARTS ALL oyster-storybook DYNOS**). With the old buildpack still running, this has no effect except the restart:
   ```sh
   heroku config:set VPN_ALLOWED_CIDRS="95.179.220.118/32,209.35.224.184/32,131.226.43.208/32,172.235.251.116/32,185.14.187.105/32,64.226.129.141/32,64.226.128.64/32,216.238.98.228/32,139.180.190.134/32,212.59.68.116/32,5.22.218.185/32,5.22.223.158/32,149.28.246.199/32" -a oyster-storybook
   ```
4. Switch to the merged ref explicitly, then rebuild:
   ```sh
   heroku buildpacks:set --index 2 https://github.com/oysterhr/storybook-heroku-buildpack#<MERGED_SHA> -a oyster-storybook
   ```
   Then use **Manual deploy** of `oysterhr/anywhere` master in the dashboard. The new build also rehashes the Basic auth password, which fixes the plaintext `.htpasswd`.
5. Run `scripts/test-matrix.sh storybook.oysterhr.com on` and `... off`, and grep `router_peer=` in the production logs.
6. Rollback: `heroku buildpacks:set --index 2 ...#c7512ffe3bccfe2aac34e0b9c9c28d8a92569f38` and redeploy, or for an immediate gate-off, `heroku config:unset VPN_ALLOWED_CIDRS -a oyster-storybook` (🔴 restart).
