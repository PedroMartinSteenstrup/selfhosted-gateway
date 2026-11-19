# >= 1.31.9 fixes nginx2root (CVE-2026-123634 hits resolver + variable proxy_pass, used here).
# Floating patch tag: each rebuild (--pull) picks up the latest 1.31.x.
FROM nginx:1.31-trixie

# Dynamic HTTP
ADD http.conf.template /etc/nginx/templates/http.conf.template
# Dynamic HTTPS(SNI)
ADD nginx.conf.template /etc/nginx/templates/nginx.conf.template

# Default nginx image sends logs to stdout/stderr
RUN rm /var/log/nginx/access.log /var/log/nginx/error.log

# Create files that fail2ban will be watching
RUN touch /var/log/nginx/acces.log && touch /var/log/nginx/error.log

