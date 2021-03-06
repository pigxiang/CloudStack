#!/bin/bash
# Version @VERSION@

#set -x
 
usage() {
  printf "Usage: %s [vhd file in secondary storage] [uuid of the source sr] \n" $(basename $0) 
}

cleanup()
{
  if [ ! -z $localmp ]; then 
    umount -fl $localmp
    if [ $? -eq 0 ];  then
      rmdir $localmp
    fi
  fi
}

if [ -z $1 ]; then
  usage
  echo "2#no mountpoint"
  exit 0
else
  mountpoint=${1%/*}
  vhdfilename=${1##*/}
fi

if [ -z $2 ]; then
  usage
  echo "3#no uuid of the source sr"
  exit 0
else
  sruuid=$2
fi

type=$(xe sr-param-get uuid=$sruuid param-name=type)
if [ $? -ne 0 ]; then
  echo "4#sr $sruuid doesn't exist"
  exit 0
fi

localmp=/var/run/cloud_mount/$(uuidgen -r)

mkdir -p $localmp
if [ $? -ne 0 ]; then
  echo "5#can't make dir $localmp"
  exit 0
fi

mount -o tcp,ro $mountpoint $localmp
if [ $? -ne 0 ]; then
  echo "6#can't mount $mountpoint to $localmp"
  exit 0
fi

vhdfile=$localmp/$vhdfilename
if [ ${vhdfile%.vhd} == ${vhdfile} ] ; then
  vhdfile=$(ls $vhdfile/*.vhd)
  if [ $? -ne 0 ]; then
    echo "7#There is no vhd file under $mountpoint"
    cleanup
    exit 0
  fi
fi



VHDUTIL="/opt/xensource/bin/vhd-util"

copyvhd()
{
  local desvhd=$1
  local srcvhd=$2
  local vsize=$3
  local type=$4
  local parent=`$VHDUTIL query -p -n $srcvhd`
  if [ $? -ne 0 ]; then
    echo "30#failed to query $srcvhd"
    cleanup
    exit 0
  fi
  if [ "${parent##*vhd has}" = " no parent" ]; then
    dd if=$srcvhd of=$desvhd bs=2M     
    if [ $? -ne 0 ]; then
      echo "31#failed to dd $srcvhd to $desvhd"
      cleanup
     exit 0
    fi
    if [ $type != "nfs" -a $type != "ext" ]; then
      dd if=$srcvhd of=$desvhd bs=512 seek=$(($(($vsize/512))-1)) count=1
      $VHDUTIL modify -s $vsize -n $desvhd
      if [ $? -ne 0 ]; then
        echo "32#failed to set new vhd physical size for vdi vdi $uuid"
        cleanup
        exit 0
      fi
    fi
  else
    copyvhd $desvhd $parent $vsize $type
    $VHDUTIL coalesce -p $desvhd -n $srcvhd
    if [ $? -ne 0 ]; then
      echo "32#failed to coalesce  $desvhd to $srcvhd"
      cleanup
     exit 0
    fi
  fi
}

if [ $type == "nfs" -o $type == "ext" ]; then
  uuid=$(uuidgen -r)
  desvhd=/var/run/sr-mount/$sruuid/$uuid
  copyvhd $desvhd $vhdfile 0 $type
  $VHDUTIL set -n $desvhd -f "hidden" -v "0" > /dev/null
  if [ $? -ne 0 ]; then
    echo "21#failed to set hidden to 0  $desvhd"
    cleanup
    exit 0
  fi
  mv /var/run/sr-mount/$sruuid/$uuid /var/run/sr-mount/$sruuid/${uuid}.vhd
  xe sr-scan uuid=$sruuid
  if [ $? -ne 0 ]; then
    echo "14#failed to scan sr $sruuid"
    cleanup
    exit 0
  fi
elif [ $type == "lvmoiscsi" -o $type == "lvm" -o $type == "lvmohba" ]; then
  size=$($VHDUTIL query -v -n $vhdfile)
  uuid=$(xe vdi-create sr-uuid=$sruuid virtual-size=${size}MiB type=user name-label="cloud")
  if [ $? -ne 0 ]; then
    echo "9#can not create vdi in sr $sruuid"
    cleanup
    exit 0
  fi
  lvsize=$(xe vdi-param-get uuid=$uuid param-name=physical-utilisation)
  if [ $? -ne 0 ]; then
    echo "12#failed to get physical size of vdi $uuid"
    cleanup
    exit 0
  fi
  desvhd=/dev/VG_XenStorage-$sruuid/VHD-$uuid
  lvchange -ay $desvhd
  if [ $? -ne 0 ]; then
    echo "10#lvm can not make VDI $uuid  visible"
    cleanup
    exit 0
  fi
  copyvhd $desvhd $vhdfile $lvsize $type
  $VHDUTIL set -n $desvhd -f "hidden" -v "0" > /dev/null
  if [ $? -ne 0 ]; then
    echo "22#failed to set hidden to 0  $desvhd"
    cleanup
    exit 0
  fi
  xe sr-scan uuid=$sruuid
  if [ $? -ne 0 ]; then
    echo "14#failed to scan sr $sruuid"
    cleanup
    exit 0
  fi
else 
  echo "15#doesn't support sr type $type"
  cleanup
  exit 0
fi

echo "0#$uuid"
cleanup
exit 0
