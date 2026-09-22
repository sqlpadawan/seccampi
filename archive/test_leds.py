import RPi.GPIO as GPIO
import time

GPIO.setwarnings(False)
GPIO.setmode(GPIO.BOARD)

GPIO.setup(32, GPIO.OUT)  #red led output pin
GPIO.setup(36, GPIO.OUT)  #green led output pin

GPIO.output(32, 1)  #turn on red led
GPIO.output(36, 1)  #turn on green led

time.sleep(5)

GPIO.output(32, 0)  #turn off red led
GPIO.output(36, 0)  #turn off green led