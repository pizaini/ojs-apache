# PHP + Apache for OJS3 production-ready
OJS v3 docker environment with required extensions installed for simple deployment purpose

## Spesifications
* PHP 8.2
* Custom php.ini
* Apache web server
* Enable mod rewrite
* Enable mod header
* Enable mod SSL
* Expose port 80
* Expose port 443
* Jobs enable. See https://docs.pkp.sfu.ca/admin-guide/en/deploy-jobs

## New installation
1. Pull this image
2. Run image and container will download automatically OJS v3
3. Create database
4. Run installation via URL

## Restore from backup
1. Pull this image
2. Restore OJS3 application in document root at `/var/www/html`
3. Restore `files_dir` at `/var/www/ojs-data`
4. Restore database
5. Update configuration `config.inc.php` (if needed)

## Docker run
```bash
docker run -p 8080:80 -p 8443:443 --name ojs-apache ojs-apache:latest
```

## Docker compose
```yaml
ojs3:
    image: pizaini/ojs-apache
    container_name: ojs3
    ports:
      - "8443:443"
      - "8080:80"
```

## Volumes
The OJS web and files directory is located by default in
```bash
/var/www/html
/var/www/ojs-data
```