import RPi.GPIO as GPIO
import time
import os
from pathlib import Path

GPIO.setwarnings(False)
GPIO.setmode(GPIO.BOARD)

GPIO.setup(8, GPIO.IN)   #read output from pir motion sensor
GPIO.setup(32, GPIO.OUT) #red led output pin
GPIO.setup(36, GPIO.OUT) #green led output pin

GPIO.output(36,0) #turn off green led
GPIO.output(32,0) #turn off red led

while True:
    i=GPIO.input(8)
    print("i==",i)
    if i==0:              #when output from motion sensor is low
        print(time.strftime("%Y%m%d") + "_" + time.strftime("%H%M") + "::no intruders",i)
        GPIO.output(36,1) #turn on green led
        GPIO.output(32,0) #turn off red led
        time.sleep(2)     #0.1
    elif i==1:            #when output from motion sensor is high
        print(time.strftime("%Y%m%d") + "_" + time.strftime("%H%M") + "::intruder detected",i)
        GPIO.output(36,0) #turn off green led
        GPIO.output(32,1) #turn on red led
        #variable = (time.strftime("%b-%d-%Y-%H-%M"))
        #varImage = time.strftime("%H%M%S%f")
        #varFolder = time.strftime("%Y%m%d")
        #Path("/home/raspi/img/" + time.strftime("%Y%m%d") + "_" + time.strftime("%H%M")).mkdir(parents=True, exist_ok=True)
        #os.system("libcamera-still -t120000 --timelapse 1000 -o /home/raspi/img/" + time.strftime("%Y%m%d") + "_" + time.strftime("%H%M") + "/" + "%08d.jpg -n 1")
        #os.system("rpicam-still -t 120000 --timelapse 1000 -o /home/raspi/img/" + time.strftime("%Y%m%d") + "_" + time.strftime("%H%M") + "/" + "%08d.jpg --nopreview")
        time.sleep(120)   #2 mins to reset sensor
        