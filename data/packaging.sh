#!/bin/bash

USAGE="usage:
    tizenpkg packaging <git object> [-s] [-f spec_file]
options:
    -s    silence remove patch without question
    -f    specify a spec file
    -h    print this info
"

INFO_COLOR='\e[0;32m' # green
WARN_COLOR='\e[0;33m' # yellow
ERR_COLOR='\e[0;31m' # red
ASK_COLOR='\e[0;34m' # blue
NO_COLOR='\e[0m'


die()
{
    echo -e "${ERR_COLOR}Fatal Error:"
    echo -e "    " "$@${NO_COLOR}"
    echo ""
    echo "$USAGE"
    echo ""
    exit 
}

info_msg()
{
    echo -e "${INFO_COLOR}$@ ${NO_COLOR}"
}

# Run under release branch, update spec file version, input: new_version, spec
# Global env: spec
update_version()
{
    tag=$1
    spec=$2

    version=${tag#v}
    
    if [ -z "$spec" -a $(ls *.spec|wc -l) != '1' ]; then
        die "Found none or more the one spec file, please create or specify one"
    fi

    # Get spec file if not specified
    if [ -z "$spec" ]; then
        spec=$(ls *.spec)
    fi
    # Validation check
    grep "^Version:" $spec > /dev/null ||die "Invalid spec file format: There must be a line 'Version:   x.x.x' "

    cp $spec $spec.origin
    
    sed -i "s/\(^Version:[\t ]*\).*/\1$version/g" $spec

}

format_patches()
{
    tag=$1
    git_obj=$2

    git checkout $git_obj 
    patch_list=$(git format-patch $tag -o tizen-patches/)

    if [ -n "$patch_list" ]; then
        info_msg "Patch(es) list"
        for patch in $patch_list
        do
            echo "    " $(basename $patch)
        done
        echo ""
    fi
}

# Run under release branch, update patch list in spec file: input: git_obj
# Global env: spec, patch_list, silence_remove
#
# Work process:
#      1. distinguish the patch(es) need kept 
#      2. remove the other(dropped)
#      3. insert the new added
#
update_patches()
{
    if [ -z "$spec" ]; then
        die "Internal Error, no spec file found"
    fi

    # Find the patches to be kept
    for patch in $patch_list
    do
        line=$(grep "Patch[0-9]*:.*$(basename $patch|sed 's/[0-9]*-//')" $spec)
        if [ -n "$line" ]; then
            sed -i "s/$line/#PATCHKEPT#$line/" $spec
        else
            newadd_patch="$newadd_patch $patch"
        fi
    done

    # Remove old patches
    toberemove_patch=$(grep "^Patch[0-9]*:" $spec |awk '{print $2}')
    
    if [ -n "$toberemove_patch" ]; then
        echo "----------------------------------------"
        info_msg "The following patch(es) removed:"
        for patch in $toberemove_patch
        do
            if [ -z "$silence_remove" ];then
                echo -n -e "${ASK_COLOR}Remove patch: $patch? ${NO_COLOR}(Y/n)"
                read yn
            else
                info_msg "Remove patch: $patch ?(Y/n)"y
                yn=$silence_remove
            fi

            case $yn in
                [Nn]* )
                    info_msg "Patch $patch kept."
                    ;;
                * )
                    sed -i "/^Patch[0-9]*:.*$patch/ d" $spec
                    rm $patch
                    info_msg "Patch $patch removed."
                    ;;
            esac
        done
        echo "----------------------------------------"
    fi

    # Recover the kept patches
    sed -i "s/^#PATCHKEPT#//g" $spec

    # Remove the install part
    install_list=$(grep "^%patch[0-9]*" $spec|cut -d ' ' -f1|sed 's/%p/P/')
    for install in $install_list
    do
        grep "$install:" $spec > /dev/null
        if [  "$?" != "0"  ]; then
            sed -i "/$(grep -i "$install\ -p" $spec)/ d" $spec
        fi
    done

    # Trying to insert the new add patch
    # no new patch 
    if [  -n "$newadd_patch" ]; then
        # Find the insert line num
        line_num=$(grep Patch[0-9]* -r $spec -n|tail -1|cut -d':' -f1)
        # No patch. Inster after Source
        if [ -z "$line_num" ]; then
            line_num=$(grep Source[0-9]* -r $spec -n|tail -1|cut -d':' -f1)
            num=0
        else
            # The first patch number
            num=$(grep Patch[0-9]* $spec |tail -1|sed 's/Patch\([0-9]*\):.*/\1/')
            num=$(expr $num + 1)
        fi

        [ -n "$line_num" ] || die "Can not insert the patch"
        line_num=$(expr $line_num + 1)
        sed -i "$line_num i "##PATCH_ADD##"" $spec

        for patch in $newadd_patch
        do
            # Patch defination string
            PATCH="$PATCH""Patch$num:    $(basename $patch)\n"
            # Patch installation string
            INSTALL="$INSTALL""%patch$num -p1\n"
            num=`expr $num + 1`
        done

        # Insert the new add patch
        sed -i "s/##PATCH_ADD##/$PATCH/" $spec

        # Locate the line num of the patches installation command
        line_num=$(grep -n "^%patch[0-9]*"  $spec |tail -1|cut -d':' -f1)
        # No found. trying to insert before %build
        if [ -z "$line_num" ]; then
            line_num=$(grep -n "%build" $spec |tail -1|cut -d':' -f1)
        else
            line_num=$(expr $line_num + 1)
        fi

        [ -n "$line_num" ] || die "Can not insert the patch installation command, please complete it by manual"

        sed -i "$line_num i "##PATCH_INSTALL##"" $spec

        sed -i "s/##PATCH_INSTALL##/$INSTALL/" $spec
        echo "----------------------------------------"
        info_msg "The following patch(es) added:"
        for patch in $newadd_patch
        do
            echo "    " $(basename $patch)
            mv $patch .
        done
        echo "----------------------------------------"
    fi # end of insert new add patch section

}

# Get the source tarball md5sum from remote source server, input: tag
# Golbal evn: srctar_md5sum
get_srctar_md5sum()
{
    tag=$1
    project=$2
    info_msg "Geting md5sum about package $project, at $tag"
    string=`curl -s -i -u$user:$passwd -Fjson='{"parameter": [{"name": "tag", "value": "'$tag'"},{"name":"project", "value":"'$project'"}]}' -FSubmit=Build "$HUDSON_SERVER/job/srctar_md5sum/build"`
    sleep 0.5
    
    last_id=`curl -s -u$user:$passwd "$HUDSON_SERVER/job/srctar_md5sum/lastBuild/buildNumber"`


    # In case the last commit is not made by the user, supposed the last job triggered by '$user' is the one. 
    while [ ture ]
    do
        result_json=`curl -s -u$user:$passwd "$HUDSON_SERVER/job/srctar_md5sum/$last_id/api/json"`
        username=`echo $result_json|python -mjson.tool |grep "userName" |cut -d'"' -f4`
        if [ x$username != x$user ]; then
            last_id=`expr $last_id - 1`
        else
            build_id=$last_id
            break
        fi
    done

    # Waiting until the job finished
    while [ Ture ]
    do
        length=`curl -s -u$user:$passwd "$HUDSON_SERVER/rest/projects/srctar_md5sum/$build_id/console/" | cut -d ',' -f2|cut -d ':' -f2`
        string=`curl -s -u$user:$passwd "$HUDSON_SERVER/rest/projects/srctar_md5sum/$build_id/console/content" -d 'length'=$length -G`
        echo $string|grep "Finished\:">/dev/null&&break
    done

    # Execuation result
    result_json=`curl -s -u$user:$passwd "$HUDSON_SERVER/job/srctar_md5sum/$last_id/api/json"`
    result=`echo $result_json|python -mjson.tool |grep result|cut -d '"' -f4`
        
    if [  x$result != xSUCCESS ]; then
        curl -s -u$user:$passwd "$HUDSON_SERVER/rest/projects/srctar_md5sum/$build_id/console/content" -d 'length'=$length -G
        die 'Remote Server Exception'
    else
        srctar_md5sum=$(echo $string | sed 's/.*#!#\(.*\)#!#.*/\1/')
        info_msg "md5sum info:"
        echo "    "  "$srctar_md5sum"
        echo ""
    fi
    
}

update_sources()
{
    srctar_md5sum=$@
    mv sources sources.origin
    echo "$srctar_md5sum" > sources
}


while :
do
    case $1 in
        -s) silence_remove="Y";;
        -f) spec="$2"
            shift
            ;;
        -h) echo "$USAGE"
            exit
            ;;
        [0-9a-zA-Z]*)
            git_obj=$1
            ;;
        *) break ;;

    esac
    shift
done


if [ -z "$git_obj" ]; then
    git_obj=$(git log --format="%h" -n 1)

fi

user=`git config tizen.username`
passwd=`git config tizen.password`
HUDSON_SERVER=`git config tizen.hudson`

#git branch -a|sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/'|grep "master" > /dev/null 2>&1 || die "Please run this command under master branch"

git rev-parse $git_obj > /dev/null 2>&1|| die "Invalid git object $git_obj"
git describe $git_obj --tags >/dev/null || die "No tags found"

tag=$(git describe $git_obj --abbrev=0 --tags)

git_url=`git config remote.origin.url`
project=`basename $git_url`


info_msg "Packaging at major release ${tag}, the other commit(s) formating as patch(es)"
srctar_md5sum=""
get_srctar_md5sum $tag $project

info_msg "Generating patch(es) from $tag to $git_obj, stored under tizen-patches dir"
format_patches $tag $git_obj

info_msg "Switch to release branch"
git checkout release ||die "No release branch found."


info_msg "Updating the sources file"
update_sources "$srctar_md5sum"
info_msg "done."

info_msg "Updating version info in spec file"
update_version $tag
info_msg "done."

info_msg "Updating patches in spec file"
update_patches
rm tizen-patches -r
info_msg "done."

info_msg "You're on release branch now."
info_msg "All the changes to release branch are done, please check, commit them."