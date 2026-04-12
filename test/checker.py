import os, sys
from subprocess import Popen, PIPE

class CustomError(Exception):
    def __init__(self, message):
        self.message = f"\033[91;1;4m{message}:\033[0m"
        super().__init__(self.message)


def check_output(output_file_name: str, expected_output_file_name: str) -> float:
    
    output_file = open(output_file_name, 'r')
    expected_output_file = open(expected_output_file_name, 'r')
    
    output = output_file.read().replace('\x00', '').strip().split('\n')
    expected_output = expected_output_file.read().strip().split('\n')

    output = [line.strip() for line in output if line.strip()]
    expected_output = [line for line in expected_output if line.strip()]

    print(output)
    print(expected_output)
    
    sum=0
    
    for i in range(min(len(output), len(expected_output))):
        if output[i]== expected_output[i]:
            sum+=1


    return sum/len(expected_output)
