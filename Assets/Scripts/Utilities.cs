using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public class Utilities
{
    public static bool DoesTagExist(string aTag)
    {
        try
        {
            GameObject.FindGameObjectsWithTag(aTag);
            return true;
        }
        catch
        {
            return false;
        }
    }


    public static GameObject FindInActiveObjectByName(string name)
    {
        Transform[] objs = Resources.FindObjectsOfTypeAll<Transform>() as Transform[];
        for (int i = 0; i < objs.Length; i++)
        {
            if (objs[i].hideFlags == HideFlags.None)
            {
                if (objs[i].name == name)
                {
                    // Debug.Log("Found Object: " + objs[i].name);
                    return objs[i].gameObject;
                }
            }
        }
        return null;
    }

}
