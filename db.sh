#!/bin/bash 

db_init() {
  if [ ! -f db ]; then
    touch db
  fi
}

db_set () {
  if [ -z "$1" ] || [ -z "$2"]; then 
    echo "Error: key and value cannot be empty" >&2
    return 1
  fi
  if [[ "$1" == *\"* ]] || [[ "$2" == *\"* ]]; then 
    echo "Error: key and value cannot contain quotes"
    return 1
  fi
  local tp
  tp=$(date -Iseconds)
  echo "$1,\"$2\",$tp" >> db
}

db_get () {
  if [ ! -f db ]; then
    return 1
  fi 
  local line 
  line=$(grep "^$1,\" db 2>/dev/null | tail -n 1)
  if [ -z "$line" ]; then 
    return 1
  fi
  local value
  value=$(echo "$line" | sed 's/^[^,]*,"//' | sed 's/",[^,]*$//')
  if [ "$value" = "__deleted__" ]; then 
    return 1
  fi
  return 0
}

db_delete () {
  echo "$1,__deleted__" >> db
}
