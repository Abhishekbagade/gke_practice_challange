Quick run:
  export IMG="<dockerhub-username>/geo-flask:latest"
  docker build -t $IMG app && docker push $IMG
  make deploy IMG=$IMG
  URL="http://$(make -s url)"; echo $URL
  curl $URL/up
  echo hi > t.txt && curl -F file=@t.txt $URL/upload && curl $URL/file/t.txt
  make load && kubectl -n geo get hpa,pods
  make destroy
