#!/bin/env python

# $Id$

import random
import time
import os, sys

def die(words) :
    print words
    sys.exit()
    return

def check_file_exists(file_name) :
    if(not os.path.exists(file_name)) :
        die('File ' + file_name + ' does not exit')
    return

class MyFile:

    def __init__(self, name) :
        self.name = name
        self.length = None
        return

    def write(self, data, length) :
        assert self.name
        self.length = length
        fout = open(self.name, 'w')
        assert fout
        k = 0
        i = 0
        while 1 :
            x = data[i]
            fout.write('%12.6f\n' % (x))
            i = i + 1
            k = k + 1
            if k >= self.length : break
            if i > len(data) : i = 0
        fout.close()
        return

    def read(self) :
        check_file_exists(self.name)
        fin = open(self.name, 'r')
        assert fin
        while 1 :
            line = fin.readline()
            if not line : break
        fin.close()
        return

    def delete(self) :
        if(os.path.exists(self.name)) :
            os.remove(self.name)
        return

    def remove(self) :
        self.delete()
        return

class FileSystemTest :

    def __init__(self) :
        self._data = []
        self._files= []
        self._init_data()
        return

    def _init_data(self) :
        n = 1024*1024*12
        self._data = []
        mu = 0.0
        sigma=1.0
        i = 0
        while i < n :
            x = random.gauss(mu, sigma)
            self._data.append(x)
            i = i + 1
        return

    def write(self, file_index = 1, file_size = 1) :
        file_name = str(os.getpid()) + '-' + str(file_index) + '.txt'
        my_file = MyFile(name = file_name)
        self._files.append(my_file)
        my_file.write(data = self._data, length = file_size)
        return

    def read(self, n=1) :
        k = 1
        while k < n :
            i = int(random.uniform(0, len(self._files)))
            self._files[i].read()
            k = k + 1
        return

    def remove(self) :
        for f in self._files :
            f.remove()
        return

if __name__ == "__main__" :

    fs_test = FileSystemTest()

    i = 0
    while i < 2000 :
        file_size = random.uniform(1, 85000)
        file_size = int(file_size)
        fs_test.write(file_index=i, file_size=file_size)
        fs_test.read(n=2)
        i = i + 1

    #fs_test.remove()

