import RPi.GPIO as GPIO
import time
import os
from pathlib import Path

Path("/home/raspi/img/" + time.strftime("%Y%m%d") + "_" + time.strftime("%H%M")).mkdir(parents=True, exist_ok=True)
#os.system("libcamera-still -t300000 --timelapse 1000 -o /home/raspi/img/capture_%08d.jpg -n 1")
os.system("libcamera-still -t300000 --timelapse 1000 -o /home/raspi/img/" + time.strftime("%Y%m%d") + "_" + time.strftime("%H%M") + "/" + "%08d.jpg -n 1")
