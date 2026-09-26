FROM smallstep/step-ca:latest

USER root
RUN apk add --no-cache aws-cli curl jq

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# /home/step e o STEPPATH padrao da imagem oficial - fica no volume EFS.
VOLUME ["/home/step"]

ENTRYPOINT ["/entrypoint.sh"]
