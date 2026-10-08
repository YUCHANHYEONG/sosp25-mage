EXTRA_CFLAGS += -D__CN_ROCE__ #-D__CN_ROCE_TEST__

obj-m += roce4disagg.o

roce4disagg-objs := ./roce_for_disagg/roce_disagg.o \
                    ./roce_for_disagg/roce_rdma.o

all:
	make -C ../. M=$(PWD) modules

clean:
	make -C ../. M=$(PWD) clean
