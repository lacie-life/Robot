import rospy
from std_msgs.msg import String

def callback(data):
    rospy.loginfo(rospy.get_caller_id() + 'cmd: %s', data.data)

def listener():

    rospy.init_node('listener', anonymous=True)

    rospy.Subscriber('jetbot_cmd', String, callback)

    # spin() simply keeps python from exiting until this node is stopped
    rospy.spin()

if __name__ == '__main__':
    listener()