# certs

`cert.pem`, `key.pem`을 이 폴더에 둡니다. 이 폴더의 pem 파일은 git에 올라가지 않습니다.

서버에서 기존 사내 서비스와 같은 mkcert 인증 기관으로 IP용 인증서를 만듭니다.

```bash
mkcert -cert-file certs/cert.pem -key-file certs/key.pem 10.10.33.36
```
