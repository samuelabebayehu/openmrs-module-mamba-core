#!/bin/bash

# Usage info
function show_help() {
cat << EOF

Usage: ${0##*/} [-h] [-d DATABASE] [-v VW_MAKEFILE] [-s SP_MAKEFILE]...
Reads file paths in the MAKE FILEs and for each file, uses the content to create a stored procedure or a view. Stored procedures are
put in the create_stored_procedures.sql file and views in a create_views.sql file.

    -h                          display this help and exit
    -t CONFIG_DIR               JSON configuration file
    -n DB_ENGINE                Database Vendor/Engine. One of: mysql|postgres|sqlserver|oracle
    -d SOURCE_DATABASE          the Source Database (openmrs database).
    -a ANALYSIS_DATABASE        the Target/Analysis Database (where the ETL data is stored).
    -v VW_MAKEFILE              file with a list of all files with views
    -s SP_MAKEFILE              file with a list of all files with stored procedures
    -k SCHEMA                   schema in which the views and or stored procedures will be put
    -o OUTPUT_FILE              the file where the compiled output will be put
    -b BUILD_FLAG               (1 or 0) - If set to 1, engine will recompile scripts, if 0 - do nothing
    -c all                      clear all schema objects before run
    -c sp                       clear all stored procedures before run
    -c views                    clear all views before run
    -l locale                   locale to use e.g 'en'
    -p table_partition_number   Number of Columns at which to partition large Tables
    -u incremental_mode_switch  Configuration switch to turn on/off the incremental update feature

EOF
}

echo "ARG 1  : $1"
echo "ARG 2  : $2"
echo "ARG 3  : $3"
echo "ARG 4  : $4"
echo "ARG 5  : $5"
echo "ARG 6  : $6"
echo "ARG 7  : $7"
echo "ARG 8  : $8"
echo "ARG 9  : $9"
echo "ARG 10 : ${10}"
echo "ARG 11 : ${11}"
echo "ARG 12 : ${12}"
echo "ARG 13 : ${13}"
echo "ARG 14 : ${14}"
echo "ARG 15 : ${15}"
echo "ARG 16 : ${16}"

# Variable will contain the stored procedures for the Service layer Reports
# these are auto-generated by the engine from the reports.json file
create_report_procedure=""

# Variable will contain the MambaETL setup scripts
mamba_etl_starter_scripts=""

# Read in the Flat Table JSON configurations into the intermediary/consolidation table, mamba_flat_table_config
function read_config_metadata_into_mamba_flat_table_config() {

  JSON_CONTENTS="{\"flat_report_metadata\":["

  FIRST_FILE=true
  for FILENAME in "$config_dir"/*.json; do
    if [ "$FILENAME" = "$config_dir/reports.json" ]; then
        continue
    elif [ "$FIRST_FILE" = false ]; then
        JSON_CONTENTS="$JSON_CONTENTS,"
#     else
#        JSON_CONTENTS=""
    fi
    JSON_CONTENTS="$JSON_CONTENTS$(cat "$FILENAME")"
    FIRST_FILE=false
  done

  JSON_CONTENTS="$JSON_CONTENTS]}"

  # Count the number of JSON files excluding 'reports.json'
  count=$(find "$config_dir" -type f -name '*.json' ! -name 'reports.json' | wc -l)

  SQL_CONTENTS="
-- \$BEGIN
"$'

SET @report_data = '%s';

CALL sp_mamba_flat_table_config_insert_helper_manual(@report_data); -- insert manually added config JSON data from config dir
CALL sp_mamba_flat_table_config_insert_helper_auto(); -- insert automatically generated config JSON data from db
CALL sp_mamba_flat_table_config_update();
'"
-- \$END
  "

  # Replace above placeholders in SQL_CONTENTS with actual values
  SQL_CONTENTS=$(printf "$SQL_CONTENTS" "'$JSON_CONTENTS'")

  echo "$SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_flat_table_config_insert.sql"

}

# Read in the Flat Table JSON configurations into the intermediary/consolidation table (incremental table), mamba_flat_table_config_incremental
function read_config_metadata_into_mamba_flat_table_config_incremental() {

  JSON_CONTENTS="{\"flat_report_metadata\":["

  FIRST_FILE=true
  for FILENAME in "$config_dir"/*.json; do
    if [ "$FILENAME" = "$config_dir/reports.json" ]; then
        continue
    elif [ "$FIRST_FILE" = false ]; then
        JSON_CONTENTS="$JSON_CONTENTS,"
#     else
#        JSON_CONTENTS=""
    fi
    JSON_CONTENTS="$JSON_CONTENTS$(cat "$FILENAME")"
    FIRST_FILE=false
  done

  JSON_CONTENTS="$JSON_CONTENTS]}"

  # Count the number of JSON files excluding 'reports.json'
  count=$(find "$config_dir" -type f -name '*.json' ! -name 'reports.json' | wc -l)

  SQL_CONTENTS="
-- \$BEGIN
"$'

SET @report_data = '%s';

CALL sp_mamba_flat_table_config_incremental_insert_helper_manual(@report_data); -- insert manually added config JSON data from config dir
CALL sp_mamba_flat_table_config_incremental_insert_helper_auto(); -- insert automatically generated config JSON data from db
CALL sp_mamba_flat_table_config_incremental_update();
'"
-- \$END
  "

  # Replace above placeholders in SQL_CONTENTS with actual values
  SQL_CONTENTS=$(printf "$SQL_CONTENTS" "'$JSON_CONTENTS'")

  echo "$SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_flat_table_config_incremental_insert.sql"

}

# Read in the JSON configuration metadata from mamba_flat_table_config table into the mamba_concept_metadata table
function read_config_metadata_into_mamba_dim_concept_metadata() {

  SQL_CONTENTS="
-- \$BEGIN
"$'

SET @is_incremental = 0;
SET @report_data = fn_mamba_generate_json_from_mamba_flat_table_config(@is_incremental);
CALL sp_mamba_concept_metadata_insert_helper(@is_incremental, @report_data, '\''mamba_concept_metadata'\'');

'"
-- \$END
"

  echo "$SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_concept_metadata_insert.sql" #TODO: improve!!
}

# Read in the JSON configuration metadata from mamba_flat_table_config table into the mamba_concept_metadata table (incrementally)
function read_config_metadata_into_mamba_dim_concept_metadata_incremental() {

  SQL_CONTENTS="
-- \$BEGIN
"$'

SET @is_incremental = 1;
SET @report_data = fn_mamba_generate_json_from_mamba_flat_table_config(@is_incremental);
CALL sp_mamba_concept_metadata_insert_helper(@is_incremental, @report_data, '\''mamba_concept_metadata'\'');

'"
-- \$END
"

  echo "$SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_concept_metadata_incremental_insert.sql" #TODO: improve!!
}

# Read in the JSON configuration metadata for Table flattening
function read_config_metadata_for_incremental_comparison() {

  JSON_CONTENTS="{\"flat_report_metadata\":["

  FIRST_FILE=true
  for FILENAME in "$config_dir"/*.json; do
    if [ "$FILENAME" = "$config_dir/reports.json" ]; then
        continue
    elif [ "$FIRST_FILE" = false ]; then
        JSON_CONTENTS="$JSON_CONTENTS,"
#     else
#        JSON_CONTENTS=""
    fi
    JSON_CONTENTS="$JSON_CONTENTS$(cat "$FILENAME")"
    FIRST_FILE=false
  done

  JSON_CONTENTS="$JSON_CONTENTS]}"

  # Count the number of JSON files excluding 'reports.json'
  count=$(find "$config_dir" -type f -name '*.json' ! -name 'reports.json' | wc -l)

  SQL_CONTENTS="

  -- \$BEGIN
      "$'
          SET @report_data = '%s';
          SET @file_count = %d;

          -- CALL sp_extract_configured_flat_table_file_into_dim_json_incremental(@report_data); -- insert manually added config JSON data from config dir
          -- CALL sp_mamba_dim_json_incremental_insert(); -- insert automatically generated config JSON data from db
          -- CALL sp_mamba_dim_json_incremental_update();

          -- SET @report_data = fn_mamba_generate_report_array_from_automated_json_incremental();
          CALL sp_mamba_extract_report_metadata(@report_data, '\''mamba_concept_metadata'\'');
      '"
  -- \$END
  "

  # Replace above placeholders in SQL_CONTENTS with actual values
  SQL_CONTENTS=$(printf "$SQL_CONTENTS" "'$JSON_CONTENTS'" "$count")

  echo "$SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_dim_concept_metadata_incremental_insert.sql" #TODO: improve!!

}

#Read in the locale setting
function read_locale_setting() {

  LOCALE_SP_SQL_CONTENTS="
-- \$BEGIN
  "$'
  SET @concepts_locale = '%s';
  CALL sp_mamba_locale_insert_helper(@concepts_locale);
  '"
-- \$END
"

  # Replace above placeholders in SQL_CONTENTS with actual values
  LOCALE_SP_SQL_CONTENTS=$(printf "$LOCALE_SP_SQL_CONTENTS" "'$concepts_locale'")

  echo "$LOCALE_SP_SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_dim_locale_insert.sql"
}

#Read in the ETL user settings
function read_etl_user_settings() {

  USER_SETTINGS_SP_SQL_CONTENTS="

-- \$BEGIN
  "$'
  SET @concepts_locale = '%s';
  SET @table_partition = '%d';
  SET @incremental_switch = '%d';
  CALL sp_mamba_etl_user_settings_insert_helper(@concepts_locale, @table_partition, @incremental_switch);
  '"
-- \$END
"

  # Replace above placeholders in USER_SETTINGS_SP_SQL_CONTENTS with the actual values
  USER_SETTINGS_SP_SQL_CONTENTS=$(printf "$USER_SETTINGS_SP_SQL_CONTENTS" "'$concepts_locale'" "$table_partition_number" "$incremental_mode_switch")

  echo "$USER_SETTINGS_SP_SQL_CONTENTS" > "../../database/$db_engine/config/sp_mamba_etl_user_settings_insert.sql"
}

# Read the starter scripts for the MambaETL
function add_mamba_etl_starter_scripts() {


mamba_etl_starter_scripts+="

-- ---------------------------------------------------------------------------------------------
-- ----------------------------  Setup the MambaETL Scheduler  ---------------------------------
-- ---------------------------------------------------------------------------------------------


-- Enable the event etl_scheduler
SET GLOBAL event_scheduler = ON;

~-~-

-- Drop/Create the Event responsible for firing up the ETL process
DROP EVENT IF EXISTS _mamba_etl_scheduler_event;

~-~-

-- Setup ETL configurations
CALL sp_mamba_etl_setup(?, ?, ?, ?, ?);
-- pass them from the runtime properties file

~-~-

CREATE EVENT IF NOT EXISTS _mamba_etl_scheduler_event
    ON SCHEDULE EVERY ? SECOND
        STARTS CURRENT_TIMESTAMP
    DO CALL sp_mamba_etl_schedule();

~-~-
"
}

# Read in the JSON for Report Definition configuration metadata
function read_config_report_definition_metadata() {

    FILENAME="$config_dir/reports.json";
    REPORT_DEFINITION_FILE="../../database/$db_engine/config/sp_mamba_dim_report_definition_insert.sql"

    # Check if reports.json file exists
    if [ -s "$FILENAME" ] && [ -f "$FILENAME" ]; then
       json_string=$(cat "$FILENAME")

    else
      echo "reports.json file not found, is null or is not a regular file. Will not read report_definition."
      json_string='{"report_definitions": []}'

      echo "-- \$BEGIN" > "$REPORT_DEFINITION_FILE"
      echo "-- \$END" >> "$REPORT_DEFINITION_FILE"
      return
    fi

    # Get the total number of report_definitions
    total_reports=$(jq '.report_definitions | length' <<< "$json_string")

    # Iterate through each report_definition
    for ((i = 0; i < total_reports; i++)); do

        reportId=$(jq -r ".report_definitions[$i].report_id" <<< "$json_string")

        report_procedure_name="sp_mamba_${reportId}_query"
        report_columns_procedure_name="sp_mamba_${reportId}_columns_query"
        report_columns_table_name="mamba_dim_$reportId"

        sql_query=$(jq -r ".report_definitions[$i].report_sql.sql_query" <<< "$json_string")
        # echo "SQL Query: $sql_query"

        # Iterate through query_params and save values before printing
        query_params=$(jq -c ".report_definitions[$i].report_sql.query_params[] | select(length > 0) | {name, type}" <<< "$json_string")
        in_parameters=""
        while IFS= read -r entry; do
            queryName=$(jq -r '.name' <<< "$entry")
            queryType=$(jq -r '.type' <<< "$entry")

            # Check if queryName and queryType are not null or empty before concatenating
            if [[ -n "$queryName" && -n "$queryType" ]]; then
                in_parameters+="IN $queryName $queryType, "
            fi
        done <<< "$query_params"

        # Remove trailing comma
        in_parameters="${in_parameters%, }"

        # Print concatenated pairs if there are any
        #if [ -n "$in_parameters" ]; then
        #    echo "Query Params: $in_parameters"
        #fi

create_report_procedure+="

-- ---------------------------------------------------------------------------------------------
-- ----------------------  $report_procedure_name  ----------------------------
-- ---------------------------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS $report_procedure_name;

DELIMITER //

CREATE PROCEDURE $report_procedure_name($in_parameters)
BEGIN

$sql_query;

END //

DELIMITER ;

"

create_report_procedure+="

-- ---------------------------------------------------------------------------------------------
-- ----------------------  $report_columns_procedure_name  ----------------------------
-- ---------------------------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS $report_columns_procedure_name;

DELIMITER //

CREATE PROCEDURE $report_columns_procedure_name($in_parameters)
BEGIN

-- Create Table to store report column names with no rows
DROP TABLE IF EXISTS $report_columns_table_name;
CREATE TABLE $report_columns_table_name AS
$sql_query
LIMIT 0;

-- Select report column names from Table
SELECT GROUP_CONCAT(COLUMN_NAME SEPARATOR ', ')
INTO @column_names
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = '$report_columns_table_name';

-- Update Table with report column names
UPDATE mamba_dim_report_definition
SET result_column_names = @column_names
WHERE report_id='$reportId';

END //

DELIMITER ;

"
    done

    # Now Read in the contents for the Mysql Part - to insert into Tables
    if [ ! -z "$FILENAME" ] && [ -f "$FILENAME" ]; then

        JSON_CONTENTS=$(cat "$FILENAME" | sed "s/'/''/g") # Read in the contents for the JSON file and escape single quotes

        REPORT_DEFINITION_CONTENT=$(cat <<EOF
-- \$BEGIN
SET @report_definition_json = '$JSON_CONTENTS';
CALL sp_mamba_extract_report_definition_metadata(@report_definition_json, 'mamba_dim_report_definition');
-- \$END
EOF
)
    fi

    echo "$REPORT_DEFINITION_CONTENT" > "$REPORT_DEFINITION_FILE" #TODO: improve!!
}

function make_buildfile_liquibase_compatible(){

  > "$cleaned_liquibase_file"

  end_pattern="^[[:space:]]*(end|END)[[:space:]]*[/|//][[:space:]]*"
  delimiter_pattern="^[[:space:]]*(delimiter|DELIMITER)[[:space:]]*[;|//][[:space:]]*"

  while IFS= read -r line; do

    if [[ "$line" =~ $end_pattern ]]; then
      echo "END~" >> "$cleaned_liquibase_file"
#      echo "~" >> "$cleaned_liquibase_file"
      continue
    fi

    if [[ "$line" =~ $delimiter_pattern ]]; then
      continue
    fi

    # Add the character '/' on a new line before the statement 'CREATE PROCEDURE...'
    if [[ $line == "CREATE PROCEDURE"* ]]; then
      echo "~" >> "$cleaned_liquibase_file"
    fi

     # Add the character '/' on a new line before the statement 'CREATE FUNCTION...'
    if [[ $line == "CREATE FUNCTION"* ]]; then
      echo "~" >> "$cleaned_liquibase_file"
    fi

    # Write the modified line to the output file
    echo "$line" >> "$cleaned_liquibase_file"

  done < "$file_to_clean"

  #after executing use analysis_db at strt of execution, we were getting a weir error in openmrs on unlocking liquibase changelock where it was looking for the Table inside analysis_db yet it is in the Openmrs transactional db
  #so let's manually change back to use the openmrs database at the end
  use_source_db="USE $source_database;"
  echo "$use_source_db" >> "$cleaned_liquibase_file"

}

function make_buildfile_jdbc_compatible(){

  > "$cleaned_jdbc_file"

  end_pattern="^[[:space:]]*(end|END)[[:space:]]*[/|//][[:space:]]*"
  delimiter_pattern="^[[:space:]]*(delimiter|DELIMITER)[[:space:]]*[;|//][[:space:]]*"

  while IFS= read -r line; do

    if [[ "$line" =~ $end_pattern ]]; then
      echo "END;" >> "$cleaned_jdbc_file"
      echo "~-~-" >> "$cleaned_jdbc_file"
      continue
    fi

    if [[ "$line" =~ $delimiter_pattern ]]; then
      continue
    fi

    # Add the character '/' on a new line before the statement 'CREATE PROCEDURE...'
    if [[ $line == "CREATE PROCEDURE"* ]]; then
      echo "~-~-" >> "$cleaned_jdbc_file"
    fi

     # Add the character '/' on a new line before the statement 'CREATE FUNCTION...'
    if [[ $line == "CREATE FUNCTION"* ]]; then
       echo "~-~-" >> "$cleaned_jdbc_file"

    fi

    # Write the modified line to the output file
    echo "$line" >> "$cleaned_jdbc_file"

  done < "$file_to_clean"
}

function consolidateSPsCallerFile() {

  # Save the current directory
  local currentDir=$(pwd)

  # Get the base dir for the db engine we are working with
  local dbEngineBaseDir=$(readlink -f "../../database/$db_engine")

  # Search for core's p_data_processing.sql file in all subdirectories in the path: ${project.build.directory}/mamba-etl/_core/database/$db_engine
  #  local consolidatedFile=$(find "../../database/$db_engine" -name sp_mamba_data_processing_drop_and_flatten.sql -type f -print -quit)
  local consolidatedFile=$(find "$dbEngineBaseDir" -name sp_makefile -type f -print -quit)

  # Search for all files with the specified filename in the path: ${project.build.directory}/mamba-etl/_etl
  # Then get its directory name/path, so we can find a file named sp_mamba_data_processing_drop_and_flatten.sql which is in the same dir
  local sp_make_folders=$(find "../../../_etl" -name sp_makefile -type f -exec dirname {} \; | sort -u)

  local newLine="\n"
  local formatHash="#############################################################################"

  printf "\n" >> "$consolidatedFile"
  printf "\n" >> "$consolidatedFile"
  echo $formatHash >> "$consolidatedFile"
  printf "############################### ETL Scripts #################################" >> "$consolidatedFile"
  printf "\n" >> "$consolidatedFile"
  echo $formatHash >> "$consolidatedFile"

  # Loop through each folder, cd to that folder
  local temp_folder_number=1
  for folder in $sp_make_folders; do

    cd "$folder"

    printf "\n" >> "$consolidatedFile"

    # Read the sp_makefile line by line skipping comments (#) and write the file and its dir structure to a new loc.
    cat sp_makefile | grep -v "^#" | grep -v "^$" | while read -r line; do

      # echo "copying file: $line"
      # echo "to temp location: $dbEngineBaseDir"/etl/$temp_folder_number

      # Extract the file name and folder name from the line
      # filename=$(basename "$line")
      # foldername=$(dirname "$line")

      # Output the file name and folder name to the console
      #echo "File name: $filename"
      #echo "Folder name: $foldername"

      #Copy the file with its full path and folder structure to the temp folder
      rsync --relative "$line" "$dbEngineBaseDir"/etl/$temp_folder_number/

      # copy the new file path to the consolidated file
      echo "etl/$temp_folder_number/$line" >>"$consolidatedFile"

    done

    temp_folder_number=$((temp_folder_number + 1))
    cd "$currentDir"
  done

}

function create_directory_if_absent(){
    DIR="$1"

    if [ ! -d "$DIR" ]; then
        mkdir "$DIR"
    fi
}

function exit_if_file_absent(){
    FILE="$1"
    if [ ! -f "$FILE" ]; then
        echo "We couldn't find this file. Please correct and try again"
        echo "$FILE"
        exit 1
    fi
}

# Remove the first 2 occurences of the tilde (~) from a file passed as an argument
function remove_tildes_in_sql_build_file () {

    # Get the file path from the first argument
    local build_file="$1"

    # Create a temporary file to write contents without the first two tildes
    local temp_file_no_tildes=$(mktemp)

    # Use sed to remove only the first two occurrences of the tilde character
    sed 's/~//' "$build_file" | sed 's/~//' > "$temp_file_no_tildes"

    # Overwrite the original file with the content of the temporary file
    mv "$temp_file_no_tildes" "$build_file"

    # Remove the temporary file
    rm "$temp_file_no_tildes"
}

# copy mamba_main.sql to the build directory
function copy_mamba_main_sql_to_build_dir() {

    SOURCE_FILE="../../database/$db_engine/mamba_main.sql"

    # Extract the file name from the source path
    FILE_NAME=$(basename "$SOURCE_FILE")

    DESTINATION_FILE="$BUILD_DIR/$FILE_NAME"

    if cp "$SOURCE_FILE" "$DESTINATION_FILE"; then
        echo "mamba main sql file copied successfully to $DESTINATION_FILE."
    else
        echo "BUILD_DIR: $BUILD_DIR"
        echo "Failed to copy $SOURCE_FILE to $DESTINATION_FILE" >&2
        return 1
    fi
}


BUILD_DIR=""
sp_out_file="create_stored_procedures.sql"
vw_out_file="create_views.sql"
makefile=""
source_database=""
analysis_database=""
concepts_locale=""
table_partition_number=""
incremental_mode_switch=""
config_dir=""
cleaned_liquibase_file=""
cleaned_jdbc_file=""
file_to_clean=""
db_engine=""
views=""
stored_procedures=""
schema=""
objects=""
OPTIND=1
IFS='
'

while getopts ":h:t:n:d:a:v:s:k:o:c:l:p:u:" opt; do
    case "${opt}" in
        h)
            show_help
            exit 0
            ;;
        t)  config_dir="$OPTARG"
            ;;
        n)  db_engine="$OPTARG"
            ;;
        d)  source_database="$OPTARG"
            ;;
        a)  analysis_database="$OPTARG"
            ;;
        v)  views="$OPTARG"
            ;;
        s)  stored_procedures="$OPTARG"
            ;;
        k)  schema="$OPTARG"
            ;;
        o)  out_file="$OPTARG"
            ;;
        c)  objects="$OPTARG"
            ;;
        l)  concepts_locale="$OPTARG"
            ;;
        p)  table_partition_number="$OPTARG"
            ;;
        u)  incremental_mode_switch="$OPTARG"
            ;;
        *)
            show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"

if [ ! -n "$stored_procedures" ] && [ ! -n "$views" ]
then
    show_help >&2
    exit 1
fi

if [ -n "$views" ] && [ -n "$stored_procedures" ] && [ -n "$out_file" ]
then
    echo "Warning: You can not compile both views and stored procedures if you provide an output file."
    exit 1
fi

if [ -n "$out_file" ]
then
    sp_out_file=$out_file
    vw_out_file=$out_file
fi

schema_name="$schema"
if [ ! -n "$schema" ]
then
    schema_name="dbo"
else
    schema_name="$schema"
fi

objects_to_clear="$objects"
if [ ! -n "$objects" ]
then
    objects_to_clear=""
else
    objects_to_clear="$objects"
fi

clear_message="No objects to clean out."
clear_objects_sql=""
if [ "$objects_to_clear" == "all" ]; then
    clear_message="clearing all objects in $schema_name"
    clear_objects_sql="CALL dbo.sp_xf_system_drop_all_objects_in_schema '$schema_name' "
elif [ "$objects_to_clear" == "sp" ]; then
    clear_message="clearing all stored procedures in $schema_name"
    clear_objects_sql="CALL dbo.sp_xf_system_drop_all_stored_procedures_in_schema '$schema_name' "
elif [ "$objects_to_clear" == "views" ] || [ "$objects_to_clear" == "view" ] || [ "$objects_to_clear" == "v" ]; then
    clear_message="clearing all views in $schema_name"
    clear_objects_sql="CALL dbo.sp_xf_system_drop_all_views_in_schema '$schema_name' "
fi

# Read in the concepts locale setting
# Got a better implementation so commenting this code out
# read_locale_setting

# Read in the table partition number setting
# Got a better implementation so commenting this code out
# read_etl_user_settings

# Read in the JSON for Report Definition configuration metadata
read_config_report_definition_metadata

# Add the startup scripts for the ETL
add_mamba_etl_starter_scripts

# Read in the Flat Table JSON configurations into the intermediary/consolidation table, mamba_flat_table_config
read_config_metadata_into_mamba_flat_table_config

# Read in the Flat Table JSON configurations into the intermediary/consolidation table (incremental table), mamba_flat_table_config_incremental
read_config_metadata_into_mamba_flat_table_config_incremental

# Read in the JSON configuration metadata from mamba_flat_table_config table into the mamba_concept_metadata table
read_config_metadata_into_mamba_dim_concept_metadata

# Read in the JSON configuration metadata from mamba_flat_table_config table into the mamba_concept_metadata table (incrementally)
read_config_metadata_into_mamba_dim_concept_metadata_incremental

# TODO: Delete after Read in the JSON configuration metadata for incremental comparison
read_config_metadata_for_incremental_comparison

# Consolidate all the make files into one file
consolidateSPsCallerFile


if [ -n "$stored_procedures" ]
then

    makefile=$stored_procedures
    exit_if_file_absent "$makefile"

    WORKING_DIR=$(dirname "$makefile")
    BUILD_DIR="$WORKING_DIR/build"
    create_directory_if_absent "$BUILD_DIR"

    # all_stored_procedures="USE $analysis_database;
    all_stored_procedures="
        $clear_objects_sql
    "

    if [ ! -n "$source_database" ]
    then
        all_stored_procedures=""
    fi

    if [ ! -n "$analysis_database" ]
    then
        all_stored_procedures=""
    fi

    # if any of the files doesn't exist, do not process
    for file_path in $(sed -E '/^[[:blank:]]*(#|$)/d; s/#.*//' $makefile)
    do
        if [ ! -f "$WORKING_DIR/$file_path" ]
        then
            echo "Warning: Could not process stored procedures. File '$file_path' does not exist."
            exit 1
        fi
    done

    sp_name=""

    for file_path in $(sed -E '/^[[:blank:]]*(#|$)/d; s/#.*//' $makefile)
    do
        # create a stored procedure
        file_name=$(basename "$file_path" ".sql")
        sp_name="$file_name"
        sp_body=$(awk '/-- \$BEGIN/,/-- \$END/' $WORKING_DIR/$file_path)

        prefix='-- $BEGIN'
        suffix='-- $END'

        #sp_body=${sp_body#"$prefix"}
        #sp_body=${sp_body%"$suffix"}

        if [ -z "$sp_body" ]
        then
              sp_body=`cat $WORKING_DIR/$file_path`
              sp_create_statement="
-- ---------------------------------------------------------------------------------------------
-- ----------------------  $sp_name  ----------------------------
-- ---------------------------------------------------------------------------------------------

$sp_body

"
        else
            sp_create_statement="
-- ---------------------------------------------------------------------------------------------
-- ----------------------  $sp_name  ----------------------------
-- ---------------------------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS $sp_name;

DELIMITER //

CREATE PROCEDURE $sp_name()
BEGIN

DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    GET DIAGNOSTICS CONDITION 1

    @message_text = MESSAGE_TEXT,
    @mysql_errno = MYSQL_ERRNO,
    @returned_sqlstate = RETURNED_SQLSTATE;

    CALL sp_mamba_etl_error_log_insert('$sp_name', @message_text, @mysql_errno, @returned_sqlstate);

    UPDATE _mamba_etl_schedule
    SET end_time                   = NOW(),
        completion_status          = 'ERROR',
        transaction_status         = 'COMPLETED',
        success_or_error_message   = CONCAT('$sp_name', ', ', @mysql_errno, ', ', @message_text)
        WHERE id = (SELECT last_etl_schedule_insert_id FROM _mamba_etl_user_settings ORDER BY id DESC LIMIT 1);

    RESIGNAL;
END;

$sp_body
END //

DELIMITER ;
"
        fi

        all_stored_procedures="$all_stored_procedures
        $sp_create_statement"
    done

    ### SG - replace any place holders in the script e.g.$target_database
    ### all_stored_procedures="${all_stored_procedures//'$target_database'/'$analysis_database'}" commented out since we are not using it now
    ### all_stored_procedures="${all_stored_procedures//\$target_database/'$analysis_database'}" even this works!!

    ### Add the reporting SPs created above if any
    all_stored_procedures+="$create_report_procedure"

    ### Add the MambaETL starter scripts that schedule the ETL
    all_stored_procedures+="$mamba_etl_starter_scripts"

    ### write built contents (final SQL file contents) to the build output file
    echo "$all_stored_procedures" > "$BUILD_DIR/$sp_out_file"

    ### SG - Clean up build file to make it Liquibase compatible ###
    file_to_clean="$BUILD_DIR/$sp_out_file"

    ## Automate the Create Analysis Database command at the beginning of the script
    create_target_db="CREATE database IF NOT EXISTS $analysis_database;"$'\n~-~-\n' #TODO: This also adds to the create_stored_procedures.sql file -> This needs to be corrected to only add to the liquibase cleaned file

    ## Add the target database to use at the beginning of the script
    use_target_db="USE $analysis_database;"$'\n~-~-\n' #TODO: This also adds to the create_stored_procedures.sql file -> This needs to be corrected to only add to the liquibase cleaned file

    # Create a temporary file with the text to prepend
    temp_file=$(mktemp)

    # Add 'create database' command text to the temporary file
    echo "$create_target_db" > "$temp_file"

    # Append 'use database' command text to the temporary file
    echo "$use_target_db" >> "$temp_file"

    # Append the original file's content to the temporary file
    cat "$file_to_clean" >> "$temp_file"

    # Overwrite the original file with the contents of the temporary file
    mv "$temp_file" "$file_to_clean"

    # Remove the temporary file
    rm "$temp_file"


    ## Replace source database placeholder name

    temp_file=$(mktemp)

    # Search for any occurrences of 'mamba_source_db' and  awk to perform the replacement
    awk -v search="mamba_source_db" -v replace="$source_database" '{ gsub(search, replace) }1' "$file_to_clean" > "$temp_file"

    # Overwrite the original file with the contents of the temporary file
    mv "$temp_file" "$file_to_clean"

    # Remove the temporary file
    rm "$temp_file"

    cleaned_liquibase_file="$BUILD_DIR/liquibase_$sp_out_file"
    cleaned_jdbc_file="$BUILD_DIR/jdbc_$sp_out_file"

    make_buildfile_liquibase_compatible
    make_buildfile_jdbc_compatible

    #remove tilde characters from the build files
    remove_tildes_in_sql_build_file "$BUILD_DIR/$sp_out_file"
    #remove_tildes_in_sql_build_file "$cleaned_jdbc_file"
fi

if [ -n "$views" ]
then

    makefile=$views
    exit_if_file_absent "$makefile"

    WORKING_DIR=$(dirname "$makefile")
    BUILD_DIR="$WORKING_DIR/build"
    create_directory_if_absent "$BUILD_DIR"

    # views_body="USE $analysis_database;
    views_body="

$clear_objects_sql

"
    if [ ! -n "$source_database" ]
    then
        views_body=""
    fi

    if [ ! -n "$analysis_database" ]
    then
        views_body=""
    fi

    # if any of the files doesnt exist, do not process
    for file_path in $(sed -E '/^[[:blank:]]*(#|$)/d; s/#.*//' $makefile)
    do
        if [ ! -f "$WORKING_DIR/$file_path" ]
        then
            echo "Warning: Could not process. File '$file_path' does not exist."
            exit 1
        fi
    done

    for file_path in $(sed -E '/^[[:blank:]]*(#|$)/d; s/#.*//' $makefile)
    do
        # create view
        file_name=$(basename "$file_path" ".sql")
        vw_name="$file_name"
        vw_body=$(awk '/-- \$BEGIN/,/-- \$END/' $WORKING_DIR/$file_path)

        vw_header="

-- ---------------------------------------------------------------------------------------------
-- $vw_name
--

CREATE OR ALTER VIEW $vw_name AS
"

views_body="$views_body
$vw_header
$vw_body

"
    done

    echo "$views_body" > "$BUILD_DIR/$vw_out_file"

fi

# function to copy mamba_main.sql to the build directory
copy_mamba_main_sql_to_build_dir