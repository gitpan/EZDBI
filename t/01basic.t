use EZDBI;
print "1..2\n";

print "ok 1\n";

print 'not ' unless $EZDBI::VERSION == 0.04;
print "ok 2\n";

1;
