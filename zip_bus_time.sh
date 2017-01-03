# archive.sh
# Run daily at midnight UTC by cron
# 20m on m3l
set -e

cd /home/ubuntu/bus_time_zipper

if [ $# -lt 1 ]; then   # default to UTC yesterday
        DATE=$(date -d "now -1 day" +%Y-%m-%d)
else
        DATE=$(date -d "$1" +%Y-%m-%d)
fi
DATE_BASIC=$(date -d "$DATE" +%Y%m%d)
YEAR=$(date -d "$DATE" +%Y)
YEAR_MONTH=$(date -d "$DATE" +%Y-%m)
DAY_BEFORE=$(date -d "$DATE -1 day" +%Y-%m-%d)
DAY_AFTER=$(date -d "$DATE +1 day" +%Y-%m-%d)


# DOWNLOAD REPORTS FROM GOOGLE CLOUD STORAGE
#echo $(date) Downloading raw bus data...
mkdir tmp/$DAY_BEFORE tmp/$DATE tmp/$DAY_AFTER
#trickle -s -d 400 -u 100 gsutil cat 'gs://mtabusmonitor.appspot.com/siri/vm/'$DAY_BEFORE'/23:5*.csv' > monitor0.csv
trickle -s -d 1000 -u 1000 gsutil -mq cp -r 'gs://mtabusmonitor.appspot.com/siri/vm/'$DAY_BEFORE'/23:5*.csv' tmp/$DAY_BEFORE
##sleep 10
#trickle -s -d 400 -u 100 gsutil cat 'gs://mtabusmonitor.appspot.com/siri/vm/'$DATE'/0*.csv' > monitor1.csv      # 6m on m3xl
#trickle -s -d 400 -u 100 gsutil cat 'gs://mtabusmonitor.appspot.com/siri/vm/'$DATE'/1*.csv' > monitor2.csv      # 8m on m3xl
#trickle -s -d 400 -u 100 gsutil cat 'gs://mtabusmonitor.appspot.com/siri/vm/'$DATE'/2*.csv' > monitor3.csv      # 3m on m3xl
# TODO try breaking this up by 0*, 1*, 2*
trickle -s -d 1000 -u 1000 gsutil -mq cp -r 'gs://mtabusmonitor.appspot.com/siri/vm/'$DATE'/*.csv' tmp/$DATE	# 55m on m3m (at 900 kbps)
##sleep 10
#trickle -s -d 400 -u 100 gsutil cat 'gs://mtabusmonitor.appspot.com/siri/vm/'$DAY_AFTER'/00:0*.csv' > monitor4.csv              # 1m on m3xl
trickle -s -d 1000 -u 1000 gsutil -mq cp -r 'gs://mtabusmonitor.appspot.com/siri/vm/'$DAY_AFTER'/00:0*.csv' tmp/$DAY_AFTER

#cat monitor0.csv monitor1.csv monitor2.csv monitor3.csv monitor4.csv > monitor.csv
#rm monitor?.csv
cat tmp/$DAY_BEFORE/*.csv tmp/$DATE/*.csv tmp/$DAY_AFTER/*.csv > tmp/monitor.csv
rm tmp/$DAY_BEFORE/* tmp/$DATE/* tmp/$DAY_AFTER/*
rmdir tmp/$DAY_BEFORE tmp/$DATE tmp/$DAY_AFTER

# LOAD REPORTS INTO MYSQL
#echo $(date) Loading data into MySQL...
mysql -uroot bus_time -e 'DROP TABLE IF EXISTS monitor'
mysql -uroot bus_time -e 'CREATE TABLE monitor (timestamp_utc datetime NOT NULL, vehicle_id smallint(4) ZEROFILL NOT NULL, latitude decimal(8,6) NOT NULL, longitude decimal(9,6) NOT NULL, bearing decimal(5,2) NOT NULL, progress tinyint(1) NOT NULL, service_date date NOT NULL, trip_id varchar(255) NOT NULL, block_assigned bool NOT NULL, next_stop_id int(6), dist_along_route decimal(8,2), dist_from_stop decimal(8,2), PRIMARY KEY (timestamp_utc, vehicle_id)) ENGINE = MyISAM'
mysqlimport -uroot --silent --ignore --fields-terminated-by=, --lines-terminated-by="\r\n" --local bus_time tmp/monitor.csv
rm tmp/monitor.csv


# EXPORT ARCHIVE TO CSV
# timestamp, vehicle_id, latitude, longitude, bearing, progress, service_date, trip_id, block_assigned, next_stop_id, dist_along_route, dist_from_stop
#echo $(date) Exporting data to CSV file...
mysql -uroot bus_time -e "SELECT DATE_FORMAT(timestamp_utc, '%Y-%m-%dT%TZ'), LPAD(vehicle_id, 4, '0'), RTRIM(latitude)+0, RTRIM(longitude)+0, RTRIM(bearing)+0, progress, CONCAT(MID(service_date,1,4), MID(service_date,6,2), MID(service_date,9,2)), trip_id, block_assigned, IF(next_stop_id IS NOT NULL, LPAD(next_stop_id, 6, '0'), NULL), IF(dist_along_route IS NOT NULL, RTRIM(dist_along_route)+0, NULL), IF(dist_from_stop IS NOT NULL, RTRIM(dist_from_stop)+0, NULL) FROM monitor WHERE DATE(timestamp_utc) = '"$DATE"' ORDER BY timestamp_utc, vehicle_id INTO OUTFILE 'bus_time_"$DATE_BASIC".csv' FIELDS TERMINATED BY ',' LINES TERMINATED BY '\r\n'" # 20s on m3xl
mysql -uroot bus_time -e 'DROP TABLE monitor'
sudo mv '/var/lib/mysql/bus_time/bus_time_'$DATE_BASIC'.csv' tmp

# ADD HEADER LINE TO CSV
# echo -e "timestamp,vehicle_id,latitude,longitude,bearing,progress,service_date,trip_id,block_assigned,next_stop_id,dist_along_route,dist_from_stop\r" > header.csv # header line shouldn't end with a \n for some reason (maybe cat takes care of it?)
cat header.csv 'tmp/bus_time_'$DATE_BASIC'.csv' > 'tmp/bus_time_'$DATE_BASIC't.csv'
mv 'tmp/bus_time_'$DATE_BASIC't.csv' 'tmp/bus_time_'$DATE_BASIC'.csv'

# COMPRESS CSV
#echo $(date) Compressing CSV file...
xz -9 -e 'tmp/bus_time_'$DATE_BASIC'.csv' # 8-18m on m3m; 7m on m3xl

# UPLOAD ARCHIVE FILE
#echo $(date) Uploading compressed file to AWS S3...
#s3cmd put 'bus_time_'$DATE_BASIC'.csv.xz' 's3://nyc-transit-data/bus_time/'$YEAR'/'$YEAR_MONTH'/'
aws --profile foobar s3 cp 'tmp/bus_time_'$DATE_BASIC'.csv.xz' 's3://nyc-transit-data/bus_time/'$YEAR'/'$YEAR_MONTH'/' --only-show-errors
rm 'tmp/bus_time_'$DATE_BASIC'.csv.xz'

#echo $(date) Removing month-old data from GCS...
if [ $# -lt 1 ]; then
	gsutil -m -q rm -r gs://mtabusmonitor.appspot.com/siri/vm/$(date -d "now - 40 days" +%Y-%m-%d)
fi
#echo $(date) Bus data for $DATE UTC archived!

