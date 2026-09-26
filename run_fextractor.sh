#!/bin/bash -e

# NB: -e makes script to fail if internal script fails (for example when --run is enabled)

#######################################
##         CHECK ARGS
#######################################
NARGS="$#"
echo "INFO: NARGS= $NARGS"

if [ "$NARGS" -lt 1 ]; then
	echo "ERROR: Invalid number of arguments...see script usage!"
  echo ""
	echo "**************************"
  echo "***     USAGE          ***"
	echo "**************************"
 	echo "$0 [ARGS]"
	echo ""
	echo "=========================="
	echo "==    ARGUMENT LIST     =="
	echo "=========================="
	echo "*** MANDATORY ARGS ***"
	echo "--inputfile=[FILENAME] - Input file name (.json) containing images to be processed or individual input image (.png|.jpg|.fits)"
	echo ""

	echo "*** OPTIONAL ARGS ***"
	echo "=== INPUT OPTIONS ==="
	echo "--datalist-key=[KEY] - Dictionary key name to be read in input datalist. Default: data"
	echo ""
	
	echo "=== MODEL OPTIONS ==="
	echo "--model=[MODEL] - Feature extractor model/backend."
	echo "  Available models:"
	echo "    dinov2         - Hugging Face DINOv2 ViT-S/14"
	echo "    dinov3         - Hugging Face DINOv3 ViT-S/16"
	echo "    dinov2_legacy  - Original Meta DINOv2 ViT-S/14 implementation"
	echo "    siglip          - SigLIP SO400M patch14 384"
	echo "    siglip2         - SigLIP2 SO400M patch14 384"
	echo "  Default: siglip2"

	echo ""
	
	echo "=== DATA PRE-PROCESSING OPTIONS ==="
	echo "--preproc-profile=[PROFILE] - Scientific image preprocessing profile {default, simclr_radio}. Preprocessing options below override profile settings. Default: default"
	echo "--norm-min=[NORM_MIN] - MinMax normalization min value. Default: 0.0"
	echo "--norm-max=[NORM_MAX] - MinMax normalization max value. Default: 1.0"
	echo "--imgsize=[IMGSIZE] - Override model input image size in pixels. If omitted, the backend/model default is used."
	echo "  Used by backends that explicitly support wrapper-controlled resize (e.g. dinov2_legacy, siglip)."
	echo "  Hugging Face DINO backends (dinov2, dinov3) use the image size defined by their HF processor/model and ignore this option."

	echo "--nchannels=[IN_CHANS] - Override number of model input channels. If omitted, the backend/model default is used."
	echo "  This controls fextractor scientific preprocessing metadata/input handling where supported."
	echo "  Hugging Face vision backends ultimately convert the processed image to RGB before model inference."

	echo "--clipdata - Clip image pixel value in range [mean-5*stddev, mean+30*stddev]. Default: not applied"
	echo "--zscale - Apply zscale stretching to image. Enabled by default with profile=simclr_radio"
	echo "--no-zscale - Disable zscale stretching to image."
	echo "--zscale-contrast=[ZSCALE_CONTRAST] - Contrast used for zscale stretching. Default: 0.25"
	echo "--set-zero-to-min - Set zero/blank/nan pixels to image min value. Default: not applied"
	echo "--reset-meanstd - Override SigLIP processor mean/std with mean=0 and std=1. Default: disabled."
	echo "--reset-rescale - Disable SigLIP processor input rescaling. Default: disabled."
	
	echo ""
	
	echo "=== SAVE OPTIONS ==="
	echo "--outfile=[FILENAME] - Name of output file. Default: fextractor_results.json"
	
	echo "=== RUN OPTIONS ==="
	echo "--run - Run the generated run script on the local shell. If disabled only run script will be generated for later run."	
	echo "--scriptdir=[SCRIPT_DIR] - Job directory where to find scripts (default=/usr/bin)"
	echo "--modeldir=[MODEL_DIR] - Job directory where to find model & weight files (default=/opt/models)"
	echo "--jobdir=[JOB_DIR] - Job directory where to run (default=pwd)"
	echo "--outdir=[OUTPUT_DIR] - Output directory where to put run output file (default=pwd)"
	echo "--waitcopy - Wait a bit after copying output files to output dir (default=no)"
	echo "--copywaittime=[COPY_WAIT_TIME] - Time to wait after copying output files (default=30)"
	echo "--no-logredir - Do not redirect logs to output file in script "	
	echo "=========================="
  exit 1
fi


#######################################
##         PARSE ARGS
#######################################
# - Run options
JOB_DIR=""
JOB_OUTDIR=""
SCRIPT_DIR="/usr/bin"
RUN_SCRIPT=false
WAIT_COPY=false
COPY_WAIT_TIME=30
REDIRECT_LOGS=true
MODEL_DIR="/opt/models"

# - Input options
INPUTFILE=""
INPUTFILE_GIVEN=false
DATALIST_KEY="data"

# - Model options
MODEL="siglip2"
BACKEND=""

# - Shared scientific preprocessing defaults
PREPROC_PROFILE="default"
NORM_MIN=0.0
NORM_MAX=1.0
ZSCALE_CONTRAST=0.25

CLIP_DATA=""
ZSCALE_STRETCH=""
ZERO_TO_MIN_OPT=""

# - Model-specific input overrides
IMGSIZE=""
IN_CHANS=""

# - Model processor overrides
RESET_MEANSTD=""
RESET_RESCALE=""

# - Save options
OUTFILE="fextractor_results.json"

for item in "$@"
do
	case $item in 
		# **************************
		# **   MANDATORY
		# **************************
		# - INPUT OPTIONS 	
    --inputfile=*)
    	INPUTFILE=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`		
			if [ "$INPUTFILE" != "" ]; then
				INPUTFILE_GIVEN=true
			fi
    ;;
    --datalist-key=*)
    	DATALIST_KEY=`echo $item | sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    
    # **************************
		# **   OPTIONAL OPTIONS 
		# **************************
		# - MODEL options
		--model=*)
    	MODEL=`echo $item | sed 's/[-a-zA-Z0-9]*=//'`
    ;;
		
		# - PREPROC OPTIONS
		--preproc-profile=*)
    	PREPROC_PROFILE=`echo $item | sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --norm-min=*)
    	NORM_MIN=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --norm-max=*)
    	NORM_MAX=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --imgsize=*)
    	IMGSIZE=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --nchannels=*)
    	IN_CHANS=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
		--clipdata)
			CLIP_DATA="--clip-data"
		;;
		# NB: Put this before --zscale otherwise the --zscale matches also the --zscale-contrasts
    --zscale-contrast=*)
			ZSCALE_CONTRAST=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
		;;
		--zscale)
			ZSCALE_STRETCH="--zscale"
		;;
		--no-zscale)
			ZSCALE_STRETCH="--no-zscale"
		;;
		--set-zero-to-min)
			ZERO_TO_MIN_OPT="--set-zero-to-min"
		;;
		--reset-meanstd)
			RESET_MEANSTD="--reset-meanstd"
		;;
		--reset-rescale)
			RESET_RESCALE="--reset-rescale"
		;;
		 	    
    # - SAVE OPTIONS
    --outfile=*)
    	OUTFILE=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
	
		# - RUN OPTIONS
    --run*)
    	RUN_SCRIPT=true
    ;;
    --scriptdir=*)
    	SCRIPT_DIR=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --outdir=*)
    	JOB_OUTDIR=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --modeldir=*)
			MODEL_DIR=`echo "$item" | /bin/sed 's/[-a-zA-Z0-9]*=//'`
		;;
		--waitcopy*)
    	WAIT_COPY=true
    ;;
		--copywaittime=*)
    	COPY_WAIT_TIME=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --jobdir=*)
    	JOB_DIR=`echo $item | /bin/sed 's/[-a-zA-Z0-9]*=//'`
    ;;
    --no-logredir*)
			REDIRECT_LOGS=false
		;;
    
    *)
    # Unknown option
    echo "ERROR: Unknown option ($item)...exit!"
    exit 1
    ;;
	esac
done

if [ "$INPUTFILE_GIVEN" = false ]; then
  echo "ERROR: Missing or empty INPUTFILE args (hint: you must specify at least one)!"
  exit 1
fi

if [ "$JOB_DIR" = "" ]; then
  echo "WARN: Empty JOB_DIR given, setting it to pwd ($PWD) ..."
	JOB_DIR="$PWD"
fi

if [ "$JOB_OUTDIR" = "" ]; then
  echo "WARN: Empty JOB_OUTDIR given, setting it to pwd ($PWD) ..."
	JOB_OUTDIR="$PWD"
fi

#######################################
##   SET OPTIONS
#######################################
INPUT_OPTS="--inputfile=$INPUTFILE --datalist-key=$DATALIST_KEY "

PREPROC_OPTS="--profile=$PREPROC_PROFILE \
--norm-min=$NORM_MIN \
--norm-max=$NORM_MAX \
--zscale-contrast=$ZSCALE_CONTRAST \
$ZSCALE_STRETCH \
$CLIP_DATA \
$ZERO_TO_MIN_OPT "

if [ "$IMGSIZE" != "" ]; then
	PREPROC_OPTS="$PREPROC_OPTS --imgsize=$IMGSIZE "
fi

if [ "$IN_CHANS" != "" ]; then
	PREPROC_OPTS="$PREPROC_OPTS --in-chans=$IN_CHANS "
fi

PREPROC_OPTS="$PREPROC_OPTS \
$RESET_MEANSTD \
$RESET_RESCALE "


SAVE_OPTS="--outfile=$OUTFILE "

# - Resolve selected model to fextractor backend and local model path
MODEL_OPTS=""

if [ "$MODEL" = "dinov2" ]; then

	BACKEND="dinov2"
	MODELFILE="$MODEL_DIR/dinov2"

	if [ ! -d "$MODELFILE" ]; then
		echo "ERROR: DINOv2 model directory not found: $MODELFILE"
		exit 1
	fi

	MODEL_OPTS="--model=$MODELFILE "

elif [ "$MODEL" = "dinov3" ]; then

	BACKEND="dinov3"
	MODELFILE="$MODEL_DIR/dinov3"

	if [ ! -d "$MODELFILE" ]; then
		echo "ERROR: DINOv3 model directory not found: $MODELFILE"
		exit 1
	fi

	MODEL_OPTS="--model=$MODELFILE "

elif [ "$MODEL" = "dinov2_legacy" ]; then

	BACKEND="dinov2_legacy"
	MODELFILE="dinov2_vits14"
	WEIGHTFILE="$MODEL_DIR/dinov2_legacy/dinov2_vits14_pretrain.pth"
	REPO_DIR="$MODEL_DIR/dinov2_legacy/repo"

	if [ ! -d "$REPO_DIR" ]; then
		echo "ERROR: Legacy DINOv2 repository not found: $REPO_DIR"
		exit 1
	fi

	if [ ! -f "$WEIGHTFILE" ]; then
		echo "ERROR: Legacy DINOv2 weights not found: $WEIGHTFILE"
		exit 1
	fi

	MODEL_OPTS="--model=$MODELFILE --model-weights=$WEIGHTFILE "

elif [ "$MODEL" = "siglip" ]; then

	BACKEND="siglip"
	MODELFILE="$MODEL_DIR/siglip"

	if [ ! -d "$MODELFILE" ]; then
		echo "ERROR: SigLIP model directory not found: $MODELFILE"
		exit 1
	fi

	MODEL_OPTS="--model=$MODELFILE "

elif [ "$MODEL" = "siglip2" ]; then

	BACKEND="siglip2"
	MODELFILE="$MODEL_DIR/siglip2"

	if [ ! -d "$MODELFILE" ]; then
		echo "ERROR: SigLIP2 model directory not found: $MODELFILE"
		exit 1
	fi

	MODEL_OPTS="--model=$MODELFILE "

else

	echo "ERROR: Unknown/not supported MODEL argument '$MODEL'!"
	echo "Available models: dinov2, dinov3, dinov2_legacy, siglip, siglip2"
	exit 1

fi

RUN_OPTS="--backend=$BACKEND "

echo "INFO: MODEL=$MODEL"
echo "INFO: BACKEND=$BACKEND"
echo "INFO: MODEL_OPTS=$MODEL_OPTS"

#######################################
##   DEFINE GENERATE EXE SCRIPT FCN
#######################################
# - Set shfile
shfile="submit_fextractor.sh"

# - Set log file
logfile="out.log"

generate_exec_script(){

	local shfile=$1
	
	
	echo "INFO: Creating sh file $shfile ..."
	( 
			#echo "#!/bin/bash -e"
			echo "#!/bin/bash"
			
      echo " "
      echo " "

      echo 'echo "*************************************************"'
      echo 'echo "****         PREPARE JOB                     ****"'
      echo 'echo "*************************************************"'

      echo " "
       
      echo "echo \"INFO: Entering job dir $JOB_DIR ...\""
      echo "cd $JOB_DIR"

			echo " "

      echo 'echo "*************************************************"'
      echo 'echo "****         RUN FEXTRACTOR                  ****"'
      echo 'echo "*************************************************"'
				
			EXE="fextractor" 
			ARGS="$INPUT_OPTS $PREPROC_OPTS $MODEL_OPTS $SAVE_OPTS $RUN_OPTS "
			CMD="$EXE $ARGS"

			echo "date"
			echo ""
		
			echo "echo \"INFO: Running feature extractor ...\""
			
			if [ $REDIRECT_LOGS = true ]; then			
      	echo "$CMD >> $logfile 2>&1"
			else
				echo "$CMD"
      fi
      
			echo " "

			echo 'JOB_STATUS=$?'
			echo 'echo "Feature extractor run terminated with status=$JOB_STATUS"'

			echo "date"

			echo " "

      echo 'echo "*************************************************"'
      echo 'echo "****         COPY DATA TO OUTDIR             ****"'
      echo 'echo "*************************************************"'
      echo 'echo ""'
			
			if [ "$JOB_DIR" != "$JOB_OUTDIR" ]; then
				echo "echo \"INFO: Copying job outputs in $JOB_OUTDIR ...\""
				echo "ls -ltr $JOB_DIR"
				echo " "

				echo "# - Copy output data"
				echo 'tab_count=`ls -1 *.dat 2>/dev/null | wc -l`'
				echo 'if [ $tab_count != 0 ] ; then'
				echo "  echo \"INFO: Copying output table file(s) to $JOB_OUTDIR ...\""
				echo "  cp *.dat $JOB_OUTDIR"
				echo "fi"

				echo " "
				
				echo 'tab_count=`ls -1 *.json 2>/dev/null | wc -l`'
				echo 'if [ $tab_count != 0 ] ; then'
				echo "  echo \"INFO: Copying output json file(s) to $JOB_OUTDIR ...\""
				#echo "  cp *.json $JOB_OUTDIR"
				echo "	cp \"$OUTFILE\" \"$JOB_OUTDIR\""
				echo "fi"
				
				echo " "
				
				echo 'tab_count=`ls -1 *.log 2>/dev/null | wc -l`'
				echo 'if [ $tab_count != 0 ] ; then'
				echo "  echo \"INFO: Copying output log file(s) to $JOB_OUTDIR ...\""
				#echo "  cp *.log $JOB_OUTDIR"
				echo "	cp \"$logfile\" \"$JOB_OUTDIR\""
				echo "fi"
				
				echo " "
				
				#echo 'tab_count=`ls -1 *.sav 2>/dev/null | wc -l`'
				#echo 'if [ $tab_count != 0 ] ; then'
				#echo "  echo \"INFO: Copying output model & data loader file(s) to $JOB_OUTDIR ...\""
				#echo "  cp *.sav $JOB_OUTDIR"
				#echo "fi"
				
				#echo " "
		
				echo "# - Show output directory"
				echo "echo \"INFO: Show files in $JOB_OUTDIR ...\""
				echo "ls -ltr $JOB_OUTDIR"

				echo " "

				echo "# - Wait a bit after copying data"
				echo "#   NB: Needed if using rclone inside a container, otherwise nothing is copied"
				if [ $WAIT_COPY = true ]; then
           echo "sleep $COPY_WAIT_TIME"
        fi
	
			fi

      echo " "
      echo " "
      
      echo 'echo "*** END RUN ***"'

			echo 'exit $JOB_STATUS'

 	) > $shfile

	chmod +x $shfile
}
## close function generate_exec_script()

###############################
##    RUN FEATURE EXTRACTOR
###############################
# - Check if job directory exists
if [ ! -d "$JOB_DIR" ] ; then 
  echo "INFO: Job dir $JOB_DIR not existing, creating it now ..."
	mkdir -p "$JOB_DIR" 
fi

# - Moving to job directory
echo "INFO: Moving to job directory $JOB_DIR ..."
cd $JOB_DIR

# - Generate run script
echo "INFO: Creating run script file $shfile ..."
generate_exec_script "$shfile"

# - Launch run script
if [ "$RUN_SCRIPT" = true ] ; then
	echo "INFO: Running script $shfile to local shell system ..."
	$JOB_DIR/$shfile
fi


echo "*** END SUBMISSION ***"

