#!/usr/bin/perl

#
# SAMPLE USAGE:
#
# ./size_images.pl --picdir /home/mmorano/redsox2/ --remdir /home/mmorano/ --webdir /images/2004/ --outfile /home/mmorano/images.sql
#

# --------------------------------------
# EXECUTION OPTIONS
# --------------------------------------
use warnings;
use strict;


# --------------------------------------
# MODULES
# --------------------------------------
use Getopt::Long;
use File::Spec::Functions;
use File::Copy;
use Image::Magick;
use Image::ExifTool 'ImageInfo';
use POSIX;


# --------------------------------------
# CONSTANTS
# --------------------------------------
my $IMAGE_FILE_EXTENSIONS = "JPG|PNG|GIF|TGA|jpg|png|gif|tga|NEF|nef";
my $RAW_FILE_EXTENSIONS = "NEF|nef";
my $PPM_EXTENSION = "ppm";
my $JPG_EXTENSION = "jpg";
my $DCRAW_APP = "dcraw";
my $THUMB_DIR = "thumbnails";
my $FULLSIZE_DIR = "fullsize";
my $ORIG_DIR = "orig";
my $RAW_DIR = "raw";
my $MAX_FULL_WIDTH = 640;
my $MAX_FULL_HEIGHT = 480;
my $MAX_THUMB_WIDTH = 160;
my $MAX_THUMB_HEIGHT = 120;


# --------------------------------------
# SIGNAL HANDLERS
# --------------------------------------
#$SIG{__WARN__} = \&my_warn;
#$SIG{__DIE__} = \&my_die;


# --------------------------------------
# START THE APP
# --------------------------------------
main();


# --------------------------------------
# FUNCTIONS
# --------------------------------------
sub main
{
    # prepare to read in our options
    my $picdir;
    my $removePath;
    my $webPath;
    my $outfile;

    # before trying to use GetOptions, see if we have any arguments on the 
    # command line (we require one)
    $ARGV[2] or die usage();

    # now indicate the arguments we support
    &GetOptions('picdir=s' => \$picdir, 
                'remdir=s' => \$removePath,
                'webdir=s' => \$webPath,
                'outfile=s' => \$outfile);

    # now that we have the directory, let's try to open it
    &process_directory($picdir, $removePath, $webPath, $outfile);
}


sub usage
{
    print "usage: $0 --picdir <image directory> --remdir <path to remove from picdir> --webdir <absolute path to images in webapp> --outfile <path to sql file>\n";
}


sub process_directory
{
    my @args = @_;
    my $picdir = $args[0];
    my $remdir = $args[1];
    my $webdir = $args[2];
    my $outfile = $args[3];
    my $origdir = catdir($picdir, $ORIG_DIR);
    my $thumbdir = catdir($picdir, $THUMB_DIR);
    my $fulldir = catdir($picdir, $FULLSIZE_DIR);
    my $rawdir = catdir($picdir, $RAW_DIR);
    my $SQLFILE;

    # make the 4 subdirectories
    mkdir $origdir;
    mkdir $thumbdir;
    mkdir $fulldir;
    mkdir $rawdir;

    # open the directory they specified
    opendir DIR, "$picdir" or die "Couldn't open the directory: $!";

    # now open the file specified
    open($SQLFILE, ">>$outfile") or die "Couldn't open the output file: $1";

    print $SQLFILE "INSERT INTO image_category (name, teaser_image_id, year, private) VALUES ('NAME', -1, -1, 0);\n\n";

    # iterate over each file in the directory
    while($_ = readdir(DIR))
    {
        # only deal with image files we specify above
        if($_ =~ /.+\.$IMAGE_FILE_EXTENSIONS/)
        {
            # indicate what file is being processed
            print "Processing $_...\n";

            # now process this file
            &process_image($picdir, $remdir, $webdir, $origdir, 
                           $thumbdir, $fulldir, $rawdir, $_, $SQLFILE);
        }
    }

    # now close the directory
    close DIR;

    # now close the out file
    close $SQLFILE;
}


sub process_image
{
    my @args = @_;
    my $picdir = $args[0];
    my $remdir = $args[1];
    my $webdir = $args[2];
    my $origdir = $args[3];
    my $thumbdir = $args[4];
    my $fulldir = $args[5];
    my $rawdir = $args[6];
    my $file = $args[7];
    my $outfile = $args[8];
    my @origdim;
    my @thumbdim;
    my @fulldim;
    
    # get convenient paths to each image
    my $rawfile = "";
    my $srcfile = &catfile($picdir, $file);
    my $origfile = &catfile($origdir, $file);
    my $thumbfile = &catfile($thumbdir, $file);
    my $fullsizefile = &catfile($fulldir, $file);

    # determine file type
    $file =~ /.+\.(.+$)/;
    my $extension = $1;

    # force thumb and fullsize to be JPEGs
    $thumbfile =~ s/$extension/$JPG_EXTENSION/;
    $fullsizefile =~ s/$extension/$JPG_EXTENSION/;

    if($extension =~ /.+\.$RAW_FILE_EXTENSIONS/)
    {
        $rawfile = &catfile($rawdir, $file);

        # convert the raw to ppm using dcraw
        @args = ($DCRAW_APP, "-w", "-q", 3, $srcfile);
        system(@args) == 0 or die "system @args failed: $?";

        # move the raw file to the raw dir
        move($srcfile, $rawfile);

        # get the ppm name of the image
        $srcfile =~ s/$extension/$PPM_EXTENSION/;
        $origfile =~ s/$extension/$PPM_EXTENSION/;
    }

    # now move the original to the orig dir
    move($srcfile, $origfile);

    # now size the image, creating the thumb and full copies
    &size_image($origfile, $thumbfile, $fullsizefile, $rawfile,
                $outfile, $remdir, $webdir);
}


sub size_image
{
    my @args = @_;
    my $origfile = $args[0];
    my $thumbfile = $args[1];
    my $fullfile = $args[2];
    my $rawfile = $args[3];
    my $outfile = $args[4];
    my $remdir = $args[5];
    my $webdir = $args[6];
    my $origheight = 0;
    my $origwidth = 0;
    my $thumbwidth = 0;
    my $thumbheight = 0;
    my $fullwidth = 0;
    my $fullheight = 0;
    my $exif_data;

    # now get the sizes of the original image
    my @origdim = &get_image_size($origfile);
    $origheight = $origdim[1];
    $origwidth = $origdim[0];
    
    # now get the ratio of width to height on the original
    my $ratio = $origwidth / $origheight;
    my $idealratio = $MAX_FULL_WIDTH / $MAX_FULL_HEIGHT;
    
    # now check to see if the original matches the ideal ratio, or should
    # be constrained horizontally
    if($ratio >= $idealratio)
    {
        # constrain horizontally
        $thumbwidth = $MAX_THUMB_WIDTH;
        $fullwidth = $MAX_FULL_WIDTH;

        # now determine the appropriate heights, maintaining the aspect
        # ratio of the original image (as integer)
        $thumbheight = sprintf("%d", ($origheight * $thumbwidth) / $origwidth);
        $fullheight = sprintf("%d", ($origheight * $fullwidth) / $origwidth);
    }
    else
    {
        # constrain vertically
        $thumbheight = $MAX_THUMB_HEIGHT;
        $fullheight = $MAX_FULL_HEIGHT;

        # now determine the widths, maintaining the aspect ratio of the
        # original image. (as int)
        $thumbwidth = sprintf("%d", ($origwidth * $thumbheight) / $origheight);
        $fullwidth = sprintf("%d", ($origwidth * $fullheight) / $origheight);
    }

    # now that we have the final sizes, save each image using the sizes
    # specified.
    &resize_image($origfile,
                  $thumbfile,
                  $thumbwidth,
                  $thumbheight);

    &resize_image($origfile,
                  $fullfile,
                  $fullwidth,
                  $fullheight);

    # now, if the original is ppm, then we need to take the final step in converting this
    # to a jpg, then deleting the ppm (as it is huge)
    if($origfile =~ /.+\.$PPM_EXTENSION/)
    {
        my $renamed_origfile = $origfile;
        $renamed_origfile =~ s/$PPM_EXTENSION/$JPG_EXTENSION/;

        # now perform the conversion (reusing the sizer w/o applying scale change)
        &resize_image($origfile,
                      $renamed_origfile,
                      $origwidth,
                      $origheight);

        # now remove the ppm (origfile)
        unlink ($origfile);

        # now rename the orig file, so that this will appear w/ the jpg extension for the sql
        # that follows below
        $origfile = $renamed_origfile;
    }

    # now get the web paths for these images
    my $web_thumb_path = $thumbfile;
    my $web_full_path = $fullfile;
    my $web_orig_path = $origfile;

    $web_thumb_path =~ s/$remdir/$webdir/;
    $web_full_path =~ s/$remdir/$webdir/;
    $web_orig_path =~ s/$remdir/$webdir/;

    # now get the exif information from the real original
    if(length($rawfile) > 0)
    {
        # great, we have a raw file, lets pull exif data from that
        $exif_data = ImageInfo($rawfile);
    }
    else
    {
        # too bad, no raw picture, lets get anything we can from the orig
        $exif_data = ImageInfo($origfile);
    }

    # now pull out the exif data
    my $af_point = &format_exif_data($exif_data->{"AFPoint"});
    my $aperture = &format_exif_data($exif_data->{"Aperture"});
    my $contrast = &format_exif_data($exif_data->{"Contrast"});
    my $depth_of_field = &format_exif_data($exif_data->{"DOF"});
    my $digital_zoom_ratio = &format_exif_data($exif_data->{"DigitalZoomRatio"});
    my $exposure_compensation = &format_exif_data($exif_data->{"ExposureCompensation"});
    my $exposure_difference = &format_exif_data($exif_data->{"ExposureDifference"});
    my $exposure_mode = &format_exif_data($exif_data->{"ExposureMode"});
    my $exposure_time = &format_exif_data($exif_data->{"ExposureTime"});
    my $f_number = &format_exif_data($exif_data->{"FNumber"});
    my $flash = &format_exif_data($exif_data->{"Flash"});
    my $flash_exposure_compensation = &format_exif_data($exif_data->{"FlashExposureComp"});
    my $flash_mode = &format_exif_data($exif_data->{"FlashMode"});
    my $flash_setting = &format_exif_data($exif_data->{"FlashSetting"});
    my $flash_type = &format_exif_data($exif_data->{"FlashType"});
    my $focal_length = &format_exif_data($exif_data->{"FocalLength"});
    my $focal_length_in_35_mm_format = &format_exif_data($exif_data->{"FocalLengthIn35mmFormat"});
    my $focus_distance = &format_exif_data($exif_data->{"FocusDistance"});
    my $focus_mode = &format_exif_data($exif_data->{"FocusMode"});
    my $focus_position = &format_exif_data($exif_data->{"FocusPosition"});
    my $gain_control = &format_exif_data($exif_data->{"GainControl"});
    my $hue_adjustment = &format_exif_data($exif_data->{"HueAdjustment"});
    my $hyperfocal_distance = &format_exif_data($exif_data->{"HyperfocalDistance"});
    my $iso = &format_exif_data($exif_data->{"ISO"});
    my $lens_id = &format_exif_data($exif_data->{"LensID"});
    my $light_source = &format_exif_data($exif_data->{"LightSource"});
    my $make = &format_exif_data($exif_data->{"Make"});
    my $metering_mode = &format_exif_data($exif_data->{"MeteringMode"});
    my $model = &format_exif_data($exif_data->{"Model"});
    my $noise_reduction = &format_exif_data($exif_data->{"NoiseReduction"});
    my $orientation = &format_exif_data($exif_data->{"Orientation"});
    my $saturation = &format_exif_data($exif_data->{"Saturation"});
    my $scale_factor_35_efl = &format_exif_data($exif_data->{"ScaleFactor35efl"});
    my $scene_capture_type = &format_exif_data($exif_data->{"SceneCaptureType"});
    my $scene_type = &format_exif_data($exif_data->{"SceneType"});
    my $sensing_method = &format_exif_data($exif_data->{"SensingMethod"});
    my $sharpness = &format_exif_data($exif_data->{"Sharpness"});
    my $shutter_speed = &format_exif_data($exif_data->{"ShutterSpeed"});
    my $white_balance = &format_exif_data($exif_data->{"WhiteBalance"});

    # new datapoints
    my $shot_taken_date = &format_exif_data($exif_data->{"DateTimeOriginal"});
    my $exposure_program = &format_exif_data($exif_data->{"ExposureProgram"});

    # GPS datapoints
    my $gps_version_id = &format_gps_data($exif_data->{"GPSVersionID"});
    my $gps_latitude_ref = &format_gps_data($exif_data->{"GPSLatitudeRef"});
    my $gps_latitude = &format_gps_data($exif_data->{"GPSLatitude"});
    my $gps_longitude_ref = &format_gps_data($exif_data->{"GPSLongitudeRef"});
    my $gps_longitude = &format_gps_data($exif_data->{"GPSLongitude"});
    my $gps_altitude_ref = &format_gps_data($exif_data->{"GPSAltitudeRef"});
    my $gps_altitude = &format_gps_data($exif_data->{"GPSAltitude"});
    my $gps_date_stamp = &format_gps_data($exif_data->{"GPSDateStamp"});
    my $gps_time_stamp = &format_gps_data($exif_data->{"GPSTimeStamp"});
    my $gps_satellites = &format_gps_data($exif_data->{"GPSSatellites"});

    # now add this image info to the db script
    print $outfile "INSERT INTO image (category_id, thumb_height, thumb_width, full_height, full_width, orig_height, orig_width, thumbnail_path, fullsize_path, orig_path, private, af_point, aperture, contrast, depth_of_field, digital_zoom_ratio, exposure_compensation, exposure_difference, exposure_mode, exposure_time, f_number, flash, flash_exposure_compensation, flash_mode, flash_setting, flash_type, focal_length, focal_length_in_35_mm_format, focus_distance, focus_mode, focus_position, gain_control, hue_adjustment, hyperfocal_distance, iso, lens_id, light_source, make, metering_mode, model, noise_reduction, orientation, saturation, scale_factor_35_efl, scene_capture_type, scene_type, sensing_method, sharpness, shutter_speed, white_balance, shot_taken_date, exposure_program, gps_version_id, gps_latitude_ref, gps_latitude, gps_longitude_ref, gps_longitude, gps_altitude_ref, gps_altitude, gps_date_stamp, gps_time_stamp, gps_satellites) VALUES (CATEGORY_ID, $thumbheight, $thumbwidth, $fullheight, $fullwidth, $origheight, $origwidth, '$web_thumb_path', '$web_full_path', '$web_orig_path', 0, '$af_point', '$aperture', '$contrast', '$depth_of_field', '$digital_zoom_ratio', '$exposure_compensation', '$exposure_difference', '$exposure_mode', '$exposure_time', '$f_number', '$flash', '$flash_exposure_compensation', '$flash_mode', '$flash_setting', '$flash_type', '$focal_length', '$focal_length_in_35_mm_format', '$focus_distance', '$focus_mode', '$focus_position', '$gain_control', '$hue_adjustment', '$hyperfocal_distance', '$iso', '$lens_id', '$light_source', '$make', '$metering_mode', '$model', '$noise_reduction', '$orientation', '$saturation', '$scale_factor_35_efl', '$scene_capture_type', '$scene_type', '$sensing_method', '$sharpness', '$shutter_speed', '$white_balance', '$shot_taken_date', '$exposure_program', $gps_version_id, $gps_latitude_ref, $gps_latitude, $gps_longitude_ref, $gps_longitude, $gps_altitude_ref, $gps_altitude, $gps_date_stamp, $gps_time_stamp, $gps_satellites);\n";
}


sub format_exif_data
{
    my @args = @_;
    my $value = $args[0];

    if(length($value) == 0)
    {
        return "--";
    }
    else
    {
        return $value;
    }
}


sub format_gps_data
{
    my @args = @_;
    my $value = $args[0];

    if(length($value) == 0)
    {
        return "NULL";
    }
    else
    {
        $value =~ s/\'/\'\'/;
        return "'$value'";
    }
}


sub resize_image
{
    my @args = @_;
    my $origfile = $args[0];
    my $newfile = $args[1];
    my $newwidth = $args[2];
    my $newheight = $args[3];

    my $im = new Image::Magick;
    
    # now read the current source file
    $im->Read($origfile);

    # now scale the image
    $im->Scale(width=>$newwidth, height=>$newheight);

    # and save the image
    $im->Write($newfile);

    # clean up the reference
    undef $im;
}


sub get_image_size
{
    my @args = @_;
    my $file = $args[0];
    
    # get a ref to the image magick obj
    my $im = new Image::Magick;
    
    # now read the original file
    $im->Read($file);

    # now get the size of the image
    my $width = $im->Get('width');
    my $height = $im->Get('height');

    # kill our im
    undef $im;

    # now return array holding the dimensions
    return ($width, $height);
}


#sub my_warn
#{
#   usage();
#}

#sub my_die
#{
#   exit(1);
#}
