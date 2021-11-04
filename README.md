#PHP + Apache for OJS3 production-ready
OJS v3 docker environment with required extensions installed for simple deployment purpose

##Spesifications
* PHP 7.4
* Custom php.ini
* Apache web server
* Enable mod rewrite
* Enable mod header
* Enable mod SSL
* Expose port 443
* Document root `/var/www/html`
* Files dir `/var/www/ojs-data`

##New installation
1. Pull this image
2. Run image and container will download automatically OJS v3
3. Create database
4. Run installation via URL

## Restore from backup
1. Pull this image
2. Restore OJS3 application in document root
3. Restore `files_dir`
4. Restore database
5. Update configuration `config.inc.php` (if needed)
6. Run

##Docker run
```bash
docker run -p 8443:443 -v ./ojs:/var/www/ojs-data --name ojs-apache ojs-apache:latest
```

##Docker compose
```yaml
ojs-pizaini:
    image: pizaini/ojs-apache
    container_name: ojs-pizaini
    volumes:
      - type: bind
      source: ./ojs
      target: /var/www/ojs-data
    
    ports:
      - "8443:443"
```

##Volumes
Extract and copy to document root (all files in parent directory)
```bash
/var/www/html
```

The OJS files directory is located by default in
```bash
/var/www/ojs-data
```